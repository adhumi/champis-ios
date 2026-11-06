import Foundation
import MapKit
import Testing
@testable import Champis

@MainActor
struct MapModelTests {
    @Test("Curseur de jour borné à J−3 → J+7 ; libellés sans météo")
    func day() {
        let model = MapModel(apiBaseURL: URL(string: "https://champis.example")!)
        #expect(model.dayOffset == 0)
        #expect(model.dayLabel == "Aujourd'hui")
        #expect(model.dayDate == nil)
        model.setDay(12)
        #expect(model.dayOffset == 7)
        #expect(model.dayLabel == "J+7")
        model.setDay(-9)
        #expect(model.dayOffset == -3)
        #expect(model.dayLabel == "J−3")
        #expect(model.renderGeneration == 2)
    }

    @Test("Mode et couche : chaque réglage pousse un nouveau rendu")
    func settings() {
        let model = MapModel(apiBaseURL: URL(string: "https://champis.example")!)
        #expect(model.mode == .score)
        model.setMode(.terrain)
        #expect(model.mode == .terrain)
        #expect(model.renderGeneration == 1)
        model.select(layerKey: .group("cepes"))
        #expect(model.selectedLayer == nil)  // rien chargé : pas de couche connue
        #expect(model.renderGeneration == 2)
        #expect(model.legend.isEmpty)
        #expect(model.overlay.minimumZ == 6 && model.overlay.maximumZ == 15)
        model.select(latitude: 47, longitude: 6)
        #expect(model.selection == MapSelection(latitude: 47, longitude: 6))
        model.clearSelection()
        #expect(model.selection == nil)
        #expect(model.pointInfo == nil)
    }

    @Test("Appui long : le point attend le menu de terrain ; « Ajouter à mes coins » passe par la fiche")
    func longPress() {
        let model = MapModel(apiBaseURL: URL(string: "https://champis.example")!)
        #expect(model.longPressPoint == nil)
        model.longPress(latitude: 47, longitude: 6)
        #expect(model.longPressPoint == MapSelection(latitude: 47, longitude: 6))
        model.clearLongPress()
        #expect(model.longPressPoint == nil)
        #expect(model.layerSpecies.isEmpty)  // rien chargé : pas de calque, pas de « rien trouvé »

        model.requestCoin(latitude: 47, longitude: 6)
        #expect(model.coinRequestFromLongPress)
        #expect(model.selection == MapSelection(latitude: 47, longitude: 6))
        model.clearCoinRequest()
        #expect(!model.coinRequestFromLongPress)
        model.requestCoin(latitude: 47, longitude: 6)
        model.clearSelection()
        #expect(!model.coinRequestFromLongPress)  // fermer la fiche oublie la demande
    }

    @Test("Proposition hors ligne : le jeu du département, sauf déjà embarqué, déjà refusé ou absent")
    func offlineSuggestion() throws {
        let manifest = try Fixtures.decode(TilesManifest.self, Fixtures.manifestPerDeptJSON)
        let names = ["25": "Doubs"]
        let doubs = MapModel.suggestOffline(code: "25", manifest: manifest, names: names, embarked: [], declined: [])
        #expect(doubs?.code == "25")
        #expect(doubs?.name == "Doubs")
        #expect(doubs.map { MapScreen.sizeText($0) } == ByteCountFormatStyle(style: .file).format(3300))
        #expect(MapModel.suggestOffline(code: "25", manifest: manifest, names: names, embarked: ["25"], declined: []) == nil)
        #expect(MapModel.suggestOffline(code: "25", manifest: manifest, names: names, embarked: [], declined: ["25"]) == nil)
        #expect(MapModel.suggestOffline(code: "01", manifest: manifest, names: names, embarked: [], declined: []) == nil)
        #expect(MapModel.suggestOffline(code: "25", manifest: nil, names: names, embarked: [], declined: []) == nil)
        let model = MapModel(apiBaseURL: URL(string: "https://champis.example")!)
        #expect(model.offlineSuggestion == nil)
        model.declineOfflineSuggestion()  // sans proposition : rien n'est mémorisé
    }

    @Test("Plus de vue France (4 nov. 2026) : le zoom ne change aucun réglage de rendu, la couche reste à tout zoom")
    func noFranceView() {
        let model = MapModel(apiBaseURL: URL(string: "https://champis.example")!)
        let bbox = BBox(minLon: -5, minLat: 42, maxLon: 9, maxLat: 51)
        #expect(model.zoom == nil)
        model.visibleRegionChanged(bbox, zoom: 7)
        #expect(model.zoom == 7)
        #expect(model.renderGeneration == 0)  // dézoomer sous 9 ne pousse rien au rendu
        model.visibleRegionChanged(bbox, zoom: 12)
        #expect(model.renderGeneration == 0)
        #expect(model.overlay.minimumZ == 6)  // les tuiles commencent au niveau 6, à tout zoom
        #expect(model.dayDots.allSatisfy { $0.value == nil })  // sans indice : pastilles vides
    }

    @Test("Voir sur la carte : recentrage demandé et point sélectionné")
    func focus() {
        let model = MapModel(apiBaseURL: URL(string: "https://champis.example")!)
        #expect(model.focusRequest == nil)
        model.focus(latitude: 47.1, longitude: 6.3)
        #expect(model.focusRequest?.id == 1)
        #expect(model.focusRequest?.latitude == 47.1 && model.focusRequest?.longitude == 6.3)
        #expect(model.selection == MapSelection(latitude: 47.1, longitude: 6.3))
        model.focus(latitude: 47.2, longitude: 6.4)
        #expect(model.focusRequest?.id == 2)
        #expect(model.goodThreshold == nil)  // rien chargé : pas de seuil inventé
    }

    @Test("Bandeau des jours : onze pastilles datées, vides sans indice ; point dans polygone")
    func dayDotsAndContains() {
        let model = MapModel(apiBaseURL: URL(string: "https://champis.example")!)
        let dots = model.dayDots
        #expect(dots.map(\.offset) == Array(-3...7))
        #expect(dots.allSatisfy { $0.date == nil && $0.value == nil })  // pas de today, pas d'indice
        #expect(model.centerDeptCode == nil)
        #expect(model.date(forOffset: 2) == nil)
        model.visibleRegionChanged(BBox(minLon: 6, minLat: 47, maxLon: 6.4, maxLat: 47.2), zoom: 12)
        #expect(model.centerDeptCode == nil)  // limites non chargées : pas de département inventé

        // lancer de rayon sur un carré en points carte
        let ring = [MKMapPoint(x: 0, y: 0), MKMapPoint(x: 10, y: 0), MKMapPoint(x: 10, y: 10), MKMapPoint(x: 0, y: 10)]
        #expect(MapModel.contains(MKMapPoint(x: 5, y: 5), ring: ring))
        #expect(!MapModel.contains(MKMapPoint(x: 15, y: 5), ring: ring))
        #expect(!MapModel.contains(MKMapPoint(x: 5, y: -1), ring: ring))
        #expect(!MapModel.contains(MKMapPoint(x: 5, y: 5), ring: Array(ring.prefix(2))))
    }

    @Test("Onze jours du point et phrase de terrain depuis le libellé de palette")
    func pointDaysAndTerrainPhrase() throws {
        let response = try Fixtures.decode(WeatherBBoxResponse.self, Fixtures.weatherJSON)
        let rows = try #require(response.cells[0].species["boletus_edulis"])
        let days = MapModel.pointDays(rows: rows, altKey: "450", terrain: 0.5, species: "boletus_edulis")
        #expect(days.map(\.date) == ["2026-10-30", "2026-10-31"])
        #expect(days[0].value == 0.45 && days[0].leading == "boletus_edulis")
        #expect(days[1].value == 0.3)
        let missing = MapModel.pointDays(rows: rows, altKey: "750", terrain: 0.5, species: "boletus_edulis")
        #expect(missing.allSatisfy { $0.value == nil && $0.leading == nil })
        #expect(PointSheet.terrainPhrase(label: "excellent") == "terrain très favorable")
        #expect(PointSheet.terrainPhrase(label: "bon") == "terrain favorable")
        #expect(PointSheet.terrainPhrase(label: "moyen") == "terrain moyen")
        #expect(PointSheet.terrainPhrase(label: "faible") == "terrain peu favorable")
        #expect(PointSheet.terrainPhrase(label: "tres_faible") == "terrain peu favorable")
        #expect(PointSheet.terrainPhrase(label: nil) == "terrain inconnu")
    }

    @Test("Date affichée : à partir du today de l'API")
    func format() {
        #expect(!MapModel.format(iso: "2026-10-30").isEmpty)
        #expect(MapModel.format(iso: "2026-10-30") != "2026-10-30")
        #expect(MapModel.format(iso: "n'importe quoi") == "n'importe quoi")
    }

    @Test("Statut météo : cellules, date du précalcul, cache périmé, cellules manquantes")
    func status() throws {
        let response = try Fixtures.decode(WeatherBBoxResponse.self, Fixtures.weatherJSON)
        let status = MapModel.status(for: response)
        #expect(status.hasPrefix("1 cellule(s) météo"))
        #expect(status.contains("calculée le"))
        #expect(status.contains("1 sans météo"))
        #expect(!status.contains("périmé"))
        #expect(!MapModel.isComplete(response))  // une cellule manque : le prochain déplacement redemande
    }

    @Test("Météo déjà reçue : une emprise contenue dans la dernière, même couche et même jour, ne redemande rien")
    func weatherCoverage() {
        let loaded = BBox(minLon: 6, minLat: 46, maxLon: 7, maxLat: 47)
        let inside = BBox(minLon: 6.2, minLat: 46.2, maxLon: 6.8, maxLat: 46.8)
        let overlapping = BBox(minLon: 5.9, minLat: 46.2, maxLon: 6.8, maxLat: 46.8)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cepes = LayerKey.group("cepes")
        let coverage = WeatherCoverage(bbox: loaded, layer: cepes, day: nil, at: now)
        #expect(loaded.contains(inside) && loaded.contains(loaded) && !loaded.contains(overlapping))
        #expect(MapModel.weatherAlreadyCovers(coverage, layer: cepes, bbox: inside, day: nil, now: now))
        #expect(MapModel.weatherAlreadyCovers(coverage, layer: cepes, bbox: loaded, day: nil, now: now + 60))
        #expect(!MapModel.weatherAlreadyCovers(coverage, layer: cepes, bbox: overlapping, day: nil, now: now))
        #expect(!MapModel.weatherAlreadyCovers(coverage, layer: .species("boletus_edulis"), bbox: inside, day: nil, now: now))
        #expect(!MapModel.weatherAlreadyCovers(nil, layer: cepes, bbox: inside, day: nil, now: now))
        let later = now + MapModel.weatherCoverageMaxAge + 1
        #expect(!MapModel.weatherAlreadyCovers(coverage, layer: cepes, bbox: inside, day: nil, now: later))

        // les 11 jours de /weather/bbox valent pour tout jour ; un champ d'un jour ne vaut que pour lui
        #expect(MapModel.weatherAlreadyCovers(coverage, layer: cepes, bbox: inside, day: "2026-10-31", now: now))
        let field = WeatherCoverage(bbox: loaded, layer: cepes, day: "2026-10-30", at: now)
        #expect(MapModel.weatherAlreadyCovers(field, layer: cepes, bbox: inside, day: "2026-10-30", now: now))
        #expect(!MapModel.weatherAlreadyCovers(field, layer: cepes, bbox: inside, day: "2026-10-31", now: now))
        #expect(!MapModel.weatherAlreadyCovers(field, layer: cepes, bbox: inside, day: nil, now: now))
        #expect(!MapModel.weatherAlreadyCovers(field, layer: cepes, bbox: overlapping, day: "2026-10-30", now: now))
        #expect(!MapModel.weatherAlreadyCovers(field, layer: cepes, bbox: inside, day: "2026-10-30", now: later))
    }

    @Test("Sous le zoom 9, le champ compact du jour ; au zoom 9 et au-delà, /weather/bbox (4 nov. 2026)")
    func weatherRequest() {
        #expect(MapModel.fieldZoom == 9)
        #expect(MapModel.weatherRequest(zoom: 6, day: "2026-10-30") == .field(day: "2026-10-30"))
        #expect(MapModel.weatherRequest(zoom: 8.99, day: "2026-10-31") == .field(day: "2026-10-31"))
        #expect(MapModel.weatherRequest(zoom: 9, day: "2026-10-30") == .bbox)
        #expect(MapModel.weatherRequest(zoom: 14, day: "2026-10-30") == .bbox)
        let model = MapModel(apiBaseURL: URL(string: "https://champis.example")!)
        #expect(!model.usesWeatherField)  // pas encore de zoom
        model.visibleRegionChanged(BBox(minLon: -5, minLat: 42, maxLon: 9, maxLat: 51), zoom: 7)
        #expect(model.usesWeatherField)
        model.visibleRegionChanged(BBox(minLon: 6, minLat: 47, maxLon: 6.4, maxLat: 47.2), zoom: 12)
        #expect(!model.usesWeatherField)
    }

    @Test("Statut d'un champ compact : cellules, date du précalcul, périmées et manquantes en clair")
    func fieldStatus() throws {
        let field = try Fixtures.decode(WeatherFieldResponse.self, Fixtures.weatherFieldJSON)
        let status = MapModel.status(for: field)
        #expect(status.hasPrefix("2 cellule(s) météo"))
        #expect(status.contains("calculée le"))
        #expect(status.contains("cache périmé pour 1 cellule(s)"))
        #expect(status.contains("2 sans météo"))
    }

    /// Le champ compact de la fixture, complet (rien de périmé ni de manquant) : une réponse complète
    /// vaut couverture, une incomplète est redemandée au prochain déplacement.
    nonisolated static let completeFieldJSON = Fixtures.weatherFieldJSON
        .replacingOccurrences(of: "\"unavailable\": 2", with: "\"unavailable\": 0")
        .replacingOccurrences(of: "\"stale\": true,", with: "")

    /// Serveur factice : espèces, manifeste, météo bbox et champ compact ; le reste en 404.
    static func stubModel() -> (MapModel, host: String, directory: URL) {
        let host = StubURLProtocol.host()
        StubURLProtocol.set(host: host) { _, path, _ in
            switch path {
            case "/species": (200, Fixtures.catalogJSON)
            case "/tiles": (200, Fixtures.manifestJSON)
            case "/weather/bbox": (200, Fixtures.weatherJSON)
            case "/weather/field": (200, MapModelTests.completeFieldJSON)
            default: (404, #"{"detail": "inconnu"}"#)
            }
        }
        let directory = FieldStoreTests.temporaryDirectory()
        let model = MapModel(
            apiBaseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: StubURLProtocol.configuration()),
            fieldDirectory: directory.appending(path: "field"), identityStores: [MemoryIdentityStore()],
            offlineRoot: directory.appending(path: "offline")
        )
        return (model, host, directory)
    }

    static func weatherRequests(host: String) -> [(path: String, query: String)] {
        StubURLProtocol.requests(host: host)
            .filter { $0.path.hasPrefix("/weather") }
            .map { (path: $0.path, query: $0.query ?? "") }
    }

    @Test("Vue France au zoom 7 : le champ du jour est demandé, le jour change le champ, le zoom 12 repasse en bbox")
    func fieldThenBBox() async throws {
        let (model, host, directory) = Self.stubModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.load()
        #expect(model.catalog != nil && model.selectedLayer?.key == .group("cepes"))
        #expect(Self.weatherRequests(host: host).isEmpty)  // pas d'emprise encore

        // France entière (comme à l'ouverture) : le champ compact, jamais /weather/bbox
        model.visibleRegionChanged(BBox(minLon: -5, minLat: 42, maxLon: 9, maxLat: 51), zoom: 7)
        await model.awaitWeather()
        var requests = Self.weatherRequests(host: host)
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.path == "/weather/field" })
        // les deux cèpes du groupe, l'emprise avec sa marge de 0,1°, et au final le jour de l'API
        let last = try #require(requests.last)
        #expect(last.query.contains("species=boletus_aereus") && last.query.contains("species=boletus_edulis"))
        #expect(last.query.contains("min_lon=-5.10000") && last.query.contains("max_lat=51.10000"))
        #expect(last.query.contains("day=2026-10-30"))
        #expect(model.today == "2026-10-30")
        #expect(model.weather.cells.count == 2)
        #expect(model.weatherStatus?.hasPrefix("2 cellule(s) météo") == true)
        #expect(model.weatherStatus?.contains("calculée le") == true)
        #expect(model.weatherStatus?.contains("sans météo") == false)
        let generation = model.renderGeneration
        #expect(generation > 0)

        // Changer de jour sous le zoom 9 : le champ de ce jour, puis un rendu
        let before = requests.count
        model.setDay(1)
        await model.awaitWeather()
        requests = Self.weatherRequests(host: host)
        #expect(requests.count == before + 1)
        #expect(requests.last?.path == "/weather/field")
        #expect(requests.last?.query.contains("day=2026-10-31") == true)
        #expect(model.renderGeneration >= generation + 2)

        // Revenir à un jour déjà reçu pour cette emprise : rien à demander
        model.setDay(0)
        await model.awaitWeather()
        #expect(Self.weatherRequests(host: host).count == before + 1)
        // Même jour, emprise contenue dans la précédente, toujours sous le zoom 9 : rien non plus
        model.visibleRegionChanged(BBox(minLon: 0, minLat: 44, maxLon: 6, maxLat: 48), zoom: 8)
        await model.awaitWeather()
        #expect(Self.weatherRequests(host: host).count == before + 1)
        // Une autre couche : son champ
        model.select(layerKey: .species("cantharellus_cibarius"))
        await model.awaitWeather()
        let girolle = try #require(Self.weatherRequests(host: host).last)
        #expect(Self.weatherRequests(host: host).count == before + 2)
        #expect(girolle.path == "/weather/field" && girolle.query.contains("species=cantharellus_cibarius"))
        #expect(!girolle.query.contains("boletus"))
        model.select(layerKey: .group("cepes"))
        await model.awaitWeather()
        #expect(Self.weatherRequests(host: host).count == before + 2)  // couverture des cèpes gardée

        // Zoom 12 : /weather/bbox, les 11 jours, le jour ne redemande rien
        model.visibleRegionChanged(BBox(minLon: 8.3, minLat: 46.9, maxLon: 8.5, maxLat: 47.1), zoom: 12)
        await model.awaitWeather()
        let bbox = try #require(Self.weatherRequests(host: host).last)
        #expect(bbox.path == "/weather/bbox")
        #expect(bbox.query.contains("min_lon=8.20000"))
        #expect(!bbox.query.contains("day="))
        #expect(model.weatherStatus?.hasPrefix("1 cellule(s) météo") == true)
        let count = Self.weatherRequests(host: host).count
        model.setDay(2)
        await model.awaitWeather()
        #expect(Self.weatherRequests(host: host).count == count)
        #expect(model.weather.cells["c_1"]?.row(species: "boletus_edulis", date: "2026-10-31", altKey: "150")?.mEff == 0.6)
    }

    @Test("Étape B4 : chargement raté dit en clair, détail technique à part, reprise propre")
    func loadProblemInPlainWords() async throws {
        let (model, host, directory) = Self.stubModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        StubURLProtocol.set(host: host) { _, _, _ in (503, #"{"detail": "base indisponible"}"#) }
        await model.load()
        let problem = try #require(model.problem)
        #expect(problem.text == "Impossible de charger la carte : le serveur est momentanément indisponible")
        #expect(problem.detail == "HTTP 503 : base indisponible")
        #expect(problem.retryable)

        StubURLProtocol.set(host: host) { _, path, _ in
            switch path {
            case "/species": (200, Fixtures.catalogJSON)
            case "/tiles": (200, Fixtures.manifestJSON)
            default: (404, #"{"detail": "inconnu"}"#)
            }
        }
        await model.load()
        #expect(model.problem == nil)
        #expect(model.catalog != nil)
    }

    @Test("Étape B4 : « Noter » n'apparaît que quand la carte connaît ma position")
    func userFixShowsNote() {
        let (model, _, directory) = Self.stubModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!model.hasUserFix)
        model.userLocationChanged(LocationProvider.Fix(latitude: 46.9, longitude: 6.35, accuracyM: 12))
        #expect(model.hasUserFix)
        #expect(model.currentFix?.accuracyM == 12)
        model.userLocationChanged(nil)
        #expect(!model.hasUserFix)
        #expect(model.currentFix == nil)
    }

    @Test("Mode terrain : aucune météo demandée, à aucun zoom")
    func terrainAsksNothing() async throws {
        let (model, host, directory) = Self.stubModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.load()
        model.setMode(.terrain)
        model.visibleRegionChanged(BBox(minLon: -5, minLat: 42, maxLon: 9, maxLat: 51), zoom: 7)
        await model.awaitWeather()
        model.visibleRegionChanged(BBox(minLon: 8.3, minLat: 46.9, maxLon: 8.5, maxLat: 47.1), zoom: 12)
        await model.awaitWeather()
        #expect(Self.weatherRequests(host: host).isEmpty)
        #expect(model.weatherStatus == nil)
    }
}
