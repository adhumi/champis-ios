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
        #expect(MapScreen.url(from: "http://localhost:8000").absoluteString == "http://localhost:8000")
        #expect(ChampisAPI.defaultSiteURL.absoluteString == "https://champis.app")
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
