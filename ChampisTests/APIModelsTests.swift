import ChampisScoring
import Foundation
import Testing
@testable import Champis

struct APIModelsTests {
    @Test("GET /species : espèces, palette, couches (groupes puis espèces)")
    func catalog() throws {
        let catalog = try Fixtures.decode(SpeciesCatalog.self, Fixtures.catalogJSON)
        #expect(catalog.scoringVersion == "1.0.0")
        #expect(catalog.species.count == 3)
        #expect(catalog.palette.thresholds.count == 5)
        #expect(catalog.species["boletus_edulis"]?.group?.id == "cepes")
        #expect(catalog.species["boletus_edulis"]?.phenology.altitudeShift?.endDaysPer100m == -3)

        let layers = LayerCatalog.layers(from: catalog)
        #expect(layers.map(\.title) == ["Cèpes", "Girolles", "Cèpe bronzé", "Cèpe de Bordeaux", "Girolle"])
        #expect(layers[0].key == .group("cepes"))
        #expect(layers[0].members == ["boletus_aereus", "boletus_edulis"])
        #expect(layers[1].members == ["cantharellus_cibarius"])
        #expect(layers[2].key == .species("boletus_aereus"))
        #expect(layers[2].members == ["boletus_aereus"])

        // sélecteur d'espèce (9 nov. 2026) : nom latin en sous-titre, vignette d'une espèce
        #expect(layers.map(\.isGroup) == [true, true, false, false, false])
        #expect(layers.map(\.latin) == ["Boletus spp.", "Cantharellus spp.", "Boletus aereus", "Boletus edulis", "Cantharellus cibarius"])
        #expect(layers[0].illustration == "boletus_aereus")  // « Cèpe bronzé », plus court que « Cèpe de Bordeaux »
        #expect(layers[3].illustration == "boletus_edulis")
    }

    @Test("Sélecteur d'espèce : genres d'un groupe et espèce de sa vignette, mêmes règles que le site")
    func layerNames() {
        #expect(LayerCatalog.groupLatin(["Lactarius deliciosus", "Lactifluus volemus", "Lactarius deterrimus"]) == "Lactarius, Lactifluus spp.")
        #expect(LayerCatalog.groupLatin(["Boletus reticulatus (= B. aestivalis)", "Boletus edulis"]) == "Boletus spp.")
        #expect(LayerCatalog.groupLatin([]) == "")
        #expect(LayerCatalog.lead([(id: "c", fr: "Girolle pâle"), (id: "a", fr: "Girolle"), (id: "b", fr: "Girolle améthyste")]) == "a")
        // à égalité de longueur, la première dans l'ordre alphabétique
        #expect(LayerCatalog.lead([(id: "y", fr: "Pied bleu"), (id: "x", fr: "Bolet bai")]) == "x")
        #expect(LayerCatalog.lead([]) == nil)
    }

    @Test("GET /tiles : URL relatives résolues sur l'API en mode proxy, absolues gardées")
    func manifest() throws {
        let manifest = try Fixtures.decode(TilesManifest.self, Fixtures.manifestJSON)
        #expect(manifest.configured)
        #expect(manifest.mode == "proxy")
        #expect(manifest.tiles.count == 2)
        #expect(manifest.tiles[1].kind == "A" && manifest.tiles[1].classM == 300)

        let api = ChampisAPI(baseURL: URL(string: "https://champis.example")!)
        #expect(
            api.tileURL(manifest.tiles[0])?.absoluteString
                == "https://champis.example/tiles/T-boletus_edulis-af34c16e-p1.0.0-da1b2c3.pmtiles"
        )
        let presigned = TilesManifest.Entry(
            kind: "A", name: "A-300m-d000000.pmtiles", url: "https://bucket.example/a.pmtiles?sig=1", bytes: nil,
            species: nil, hash: nil, scoringVersion: nil, deptsHash: "000000", classM: 300, dept: nil, group: nil, channels: nil, part: nil
        )
        #expect(api.tileURL(presigned)?.host() == "bucket.example")
    }

    @Test("GET /weather/bbox : lignes par jour et par classe, detail FastAPI")
    func weather() throws {
        let response = try Fixtures.decode(WeatherBBoxResponse.self, Fixtures.weatherJSON)
        #expect(response.today == "2026-10-30")
        #expect(response.computedAt == "2026-10-30T03:12:00+00:00")
        #expect(response.cells.count == 1)
        #expect(response.unavailable == ["c_9"])
        #expect(response.retryAfter == nil)
        let cell = response.cells[0]
        #expect(cell.cell.altClasses == [150, 450])
        #expect(cell.cell.elevationM == 620)
        let row = cell.species["boletus_edulis"]?[0].byAlt["450"]
        #expect(row?.mEff == 0.9)
        #expect(row?.factor == 0.9)
        #expect(cell.species["boletus_edulis"]?.count == 2)
        // lot 2 : `summary` et `trigger_days` facultatifs (GET /weather seulement)
        #expect(row?.summary == nil && row?.triggerDays == nil)
        let detailed = cell.species["boletus_edulis"]?[1].byAlt["450"]
        #expect(detailed?.summary == ["pluie déclenchante il y a 12 jours", "sol bien humide", "pleine saison"])
        #expect(detailed?.triggerDays == 12)

        let detail = ChampisAPI.detail(in: Data(#"{"detail": "47 cellules dans l'emprise, maximum 40 : zoomez"}"#.utf8))
        #expect(detail.hasSuffix("zoomez"))
        #expect(ChampisAPI.detail(in: Data("plain".utf8)) == "plain")
    }

    @Test("Emprise : marge en degrés, nombres formatés sans locale")
    func bbox() {
        let padded = BBox(minLon: 5, minLat: 46, maxLon: 7, maxLat: 48).padded(by: 0.1)
        #expect(abs(padded.minLon - 4.9) < 1e-9)
        #expect(abs(padded.maxLat - 48.1) < 1e-9)
        #expect(ChampisAPI.format(6.123456789) == "6.12346")
        #expect(ChampisAPI.format(-0.5) == "-0.50000")
    }

    @Test("Adresse de l'API : repli sur la valeur par défaut si invalide")
    @MainActor
    func apiURL() {
        #expect(MapScreen.url(from: " https://api.example/ ").host() == "api.example")
        #expect(MapScreen.url(from: "pas une url").absoluteString == MapScreen.defaultAPIBaseURL)
        #expect(MapScreen.url(from: "").absoluteString == MapScreen.defaultAPIBaseURL)
    }

    @Test("Découpage des dépôts : l'API sur api.champis.app, l'ancienne adresse gardée lue comme la nouvelle")
    @MainActor
    func apiDomain() {
        #expect(MapScreen.defaultAPIBaseURL == "https://api.champis.app")
        #expect(MapScreen.url(from: "https://champis.app").absoluteString == "https://api.champis.app")
        #expect(MapScreen.url(from: " https://champis.app/ ").absoluteString == "https://api.champis.app")
        #expect(ChampisAPI.defaultSiteURL.absoluteString == "https://champis.app")
        #expect(ChampisAPI.officialBaseURL.absoluteString == MapScreen.defaultAPIBaseURL)
        #expect(ChampisAPI.officialBaseURL.host() == ChampisAPI.officialHost)
    }

    @Test("Adresse de l'API : https exigé, sinon l'adresse officielle", arguments: [
        "http://api.example", "http://api.champis.app", "ftp://api.example", "file:///etc/hosts", "api.example",
        "https://", "https://moi:secret@api.example", "javascript:alert(1)",
    ])
    @MainActor
    func httpsRequired(text: String) {
        #expect(MapScreen.url(from: text).absoluteString == MapScreen.defaultAPIBaseURL)
    }

    @Test("Adresse de l'API : l'officielle seule reçoit l'identifiant et les données privées")
    func officialHostOnly() throws {
        func api(_ text: String) throws -> ChampisAPI {
            ChampisAPI(baseURL: try #require(URL(string: text)))
        }
        #expect(try api("https://api.champis.app").isOfficial)
        #expect(try api("https://API.Champis.app/").isOfficial)
        #expect(try api("https://api.champis.app:443").isOfficial)
        for other in [
            "http://api.champis.app", "https://api.champis.app:8443", "https://champis.app", "https://api.champis.app.example",
            "https://exemple.fr/api.champis.app", "https://x@api.champis.app", "https://staging.example",
        ] {
            let custom = try api(other)
            #expect(!custom.isOfficial, "\(other)")
        }
        #expect(ChampisAPI.isAcceptable(try #require(URL(string: "https://staging.example"))))
        #expect(!ChampisAPI.isAcceptable(try #require(URL(string: "http://staging.example"))))
        #if DEBUG
        // développement seulement : l'API locale de champis-api
        #expect(ChampisAPI.isAcceptable(try #require(URL(string: "http://localhost:8000"))))
        #expect(ChampisAPI.isAcceptable(try #require(URL(string: "http://127.0.0.1:8000"))))
        #endif
        #expect(!ChampisAPI.isAcceptable(try #require(URL(string: "http://192.168.1.10:8000"))))
    }

    @Test("Adresse non officielle : lecture anonyme, toute requête privée refusée avant de partir")
    func customAddressIsReadOnly() async throws {
        let host = StubURLProtocol.host()
        StubURLProtocol.set(host: host) { method, path, _ in
            method == "GET" && path == "/tiles" ? (200, Fixtures.manifestJSON) : (200, "{}")
        }
        let id = UUID()
        // même client, hôte non reconnu comme officiel
        let api = ChampisAPI(
            baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: StubURLProtocol.configuration()), userID: id
        )
        #expect(!api.isOfficial)
        _ = try await api.tiles()
        #expect(StubURLProtocol.requests(host: host).map(\.user) == [nil])  // lu sans identifiant

        let coin = Coin(name: "Col", lat: 47.0, lon: 6.0, target: "cepes", altClass: 750, t: ["boletus_edulis": 0.8])
        let observation = FieldObservation(species: "boletus_edulis", lat: 47.0, lon: 6.0, date: "2026-11-13", found: false, quantity: nil)
        await #expect(throws: ChampisAPI.Failure.readOnly) { try await api.putCoins([coin], apnsToken: nil, sandbox: false, user: id) }
        await #expect(throws: ChampisAPI.Failure.readOnly) { try await api.postObservations([observation], user: id) }
        await #expect(throws: ChampisAPI.Failure.readOnly) { try await api.deleteObservations(user: id) }
        await #expect(throws: ChampisAPI.Failure.readOnly) { try await api.coins(user: id) }
        await #expect(throws: ChampisAPI.Failure.readOnly) { try await api.observations(user: id) }
        await #expect(throws: ChampisAPI.Failure.readOnly) { try await api.send("POST", "species") }
        #expect(StubURLProtocol.requests(host: host).count == 1)  // rien d'autre n'est parti
        #expect(Problem.technical(ChampisAPI.Failure.readOnly) == "Adresse d'API non officielle : rien de privé n'est envoyé")
    }

    @Test("Redirection : l'identifiant ne suit pas vers un autre hôte, ni hors de https")
    func redirectDropsIdentity() throws {
        let original = try #require(URL(string: "https://api.champis.app/coins"))
        func redirected(to text: String) throws -> String? {
            var request = URLRequest(url: try #require(URL(string: text)))
            request.setValue("11111111-1111-1111-1111-111111111111", forHTTPHeaderField: ChampisAPI.userHeader)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let out = RedirectGuard.redirected(request, from: original)
            #expect(out.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(out.url == request.url)
            return out.value(forHTTPHeaderField: ChampisAPI.userHeader)
        }
        #expect(try redirected(to: "https://api.champis.app/coins/") == "11111111-1111-1111-1111-111111111111")
        #expect(try redirected(to: "https://API.champis.app/v2/coins") != nil)
        #expect(try redirected(to: "https://ailleurs.example/coins") == nil)
        #expect(try redirected(to: "https://champis.app/coins") == nil)
        #expect(try redirected(to: "http://api.champis.app/coins") == nil)
        // sans requête d'origine connue : rien ne suit
        var request = URLRequest(url: original)
        request.setValue("x", forHTTPHeaderField: ChampisAPI.userHeader)
        #expect(RedirectGuard.redirected(request, from: nil).value(forHTTPHeaderField: ChampisAPI.userHeader) == nil)
    }

    @Test("Liens et fichiers venus du serveur : https seulement")
    func httpsLinksOnly() throws {
        #expect(ChampisAPI.httpsURL(" https://commons.wikimedia.org/wiki/File:Cep.jpg ")?.host() == "commons.wikimedia.org")
        for text in ["http://commons.wikimedia.org/wiki/File:Cep.jpg", "tel:+33123456789", "file:///etc/passwd", "champis://x", "javascript:alert(1)", "", "https://", "commons.wikimedia.org"] {
            #expect(ChampisAPI.httpsURL(text) == nil, "\(text)")
        }

        // fichier du manifeste : relatif à l'API, ou absolu en https ; jamais un autre schéma
        func entry(_ url: String) -> TilesManifest.Entry {
            TilesManifest.Entry(
                kind: "A", name: "A-300m-da1b2c3.pmtiles", url: url, bytes: 1, species: nil, hash: nil, scoringVersion: nil,
                deptsHash: "a1b2c3", classM: 300, dept: nil, group: nil, channels: nil, part: nil
            )
        }
        let api = ChampisAPI(baseURL: ChampisAPI.officialBaseURL)
        #expect(api.tileURL(entry("/tiles/A-300m-da1b2c3.pmtiles"))?.absoluteString == "https://api.champis.app/tiles/A-300m-da1b2c3.pmtiles")
        #expect(api.tileURL(entry("https://bucket.example/tiles/A.pmtiles?sig=abc"))?.host() == "bucket.example")
        #expect(api.tileURL(entry("http://bucket.example/tiles/A.pmtiles")) == nil)
        #expect(api.tileURL(entry("file:///private/var/mobile/x.pmtiles")) == nil)
        // API locale en http (développement) : ses propres fichiers seulement
        let local = ChampisAPI(baseURL: try #require(URL(string: "http://localhost:8000")))
        #expect(local.tileURL(entry("/tiles/A-300m-da1b2c3.pmtiles"))?.absoluteString == "http://localhost:8000/tiles/A-300m-da1b2c3.pmtiles")
        #expect(local.tileURL(entry("http://bucket.example/tiles/A.pmtiles")) == nil)
    }

    @Test("Limites des départements : lues sur le site, pas sur l'API")
    func departementsFromSite() async throws {
        let apiHost = StubURLProtocol.host()
        let siteHost = StubURLProtocol.host()
        StubURLProtocol.set(host: apiHost) { _, _, _ in (404, #"{"detail": "Not Found"}"#) }
        StubURLProtocol.set(host: siteHost) { method, path, _ in
            method == "GET" && path == "/web/departements.geojson"
                ? (200, #"{"type": "FeatureCollection", "features": []}"#) : (404, "{}")
        }
        let api = ChampisAPI(
            baseURL: URL(string: "https://\(apiHost)")!, siteURL: URL(string: "https://\(siteHost)")!,
            session: URLSession(configuration: StubURLProtocol.configuration())
        )
        let data = try await api.departementsGeoJSON()
        #expect(String(decoding: data, as: UTF8.self).contains("FeatureCollection"))
        #expect(StubURLProtocol.requests(host: apiHost).isEmpty)
        #expect(StubURLProtocol.requests(host: siteHost).map(\.path) == ["/web/departements.geojson"])
    }

    @Test("X-Champis-User : sur toutes les requêtes à l'API, jamais vers le site (lot BO2, 8 nov. 2026)")
    func identityOnEveryAPIRequest() async throws {
        let apiHost = StubURLProtocol.host()
        let siteHost = StubURLProtocol.host()
        StubURLProtocol.set(host: apiHost) { method, path, _ in
            method == "GET" && path == "/tiles" ? (200, Fixtures.manifestJSON) : (404, #"{"detail": "Not Found"}"#)
        }
        StubURLProtocol.set(host: siteHost) { _, _, _ in (200, #"{"type": "FeatureCollection", "features": []}"#) }
        let session = URLSession(configuration: StubURLProtocol.configuration())
        let id = UUID()
        let api = ChampisAPI(
            baseURL: URL(string: "https://\(apiHost)")!, siteURL: URL(string: "https://\(siteHost)")!,
            session: session, userID: id, trustedHost: apiHost
        )
        _ = try await api.tiles()
        _ = try await api.departementsGeoJSON()
        #expect(StubURLProtocol.requests(host: apiHost).map(\.user) == [id.uuidString.lowercased()])
        #expect(StubURLProtocol.requests(host: siteHost).map(\.user) == [nil])

        // sans identifiant (aucun magasin ne répond), rien ne part
        let anonymous = ChampisAPI(baseURL: URL(string: "https://\(apiHost)")!, session: session)
        _ = try await anonymous.tiles()
        #expect(StubURLProtocol.requests(host: apiHost).last?.user == nil)
    }

    @Test("GET /weather/field : un jour, f par espèce et classe, stale seulement si présent, manquantes comptées")
    func weatherField() throws {
        let field = try Fixtures.decode(WeatherFieldResponse.self, Fixtures.weatherFieldJSON)
        #expect(field.today == "2026-10-30")
        #expect(field.day == "2026-10-30")
        #expect(field.computedAt == "2026-10-30T03:12:00+00:00")
        #expect(field.scoringVersion == "1.0.0")
        #expect(field.cells.count == 2)
        #expect(field.unavailable == 2)
        #expect(field.anyStale)
        let c1 = field.cells[0]
        #expect(c1.id == "c_1" && !c1.stale)
        #expect(c1.f["boletus_edulis"]?["450"] == 0.9)
        #expect(c1.f["boletus_aereus"]?["150"] == 0.2)
        #expect(c1.info == WeatherCellInfo(id: "c_1", lat: 47.0, lon: 8.4, altClasses: [150, 450], elevationM: 620))
        let c3 = field.cells[1]
        #expect(c3.stale && c3.altClasses == [150] && c3.f["boletus_edulis"]?["150"] == 0.79)

        // sans aucune cellule ni précalcul : rien d'inventé
        let empty = try Fixtures.decode(WeatherFieldResponse.self, """
        {"today": "2026-10-30", "computed_at": null, "day": "2026-10-31", "scoring_version": "1.0.0", "cells": [], "unavailable": 0}
        """)
        #expect(empty.cells.isEmpty && empty.computedAt == nil && !empty.anyStale)
        #expect(MapModel.isComplete(empty))
        #expect(!MapModel.isComplete(field))
    }
}
