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

    @Test("Vue France : mode score sous le zoom seuil ; départements sans indice transparents")
    func franceView() {
        let model = MapModel(apiBaseURL: URL(string: "https://champis.example")!)
        let bbox = BBox(minLon: -5, minLat: 42, maxLon: 9, maxLat: 51)
        #expect(!model.isFranceView)
        model.visibleRegionChanged(bbox, zoom: 7)
        #expect(model.isFranceView)
        model.visibleRegionChanged(bbox, zoom: 12)
        #expect(!model.isFranceView)
        model.visibleRegionChanged(bbox, zoom: 7)
        model.setMode(.terrain)
        #expect(!model.isFranceView)
        #expect(model.deptColor(code: "25") == nil)
        model.selectDepartement(code: nil, name: nil)
        #expect(model.deptInfo?.code == nil)
        model.selectDepartement(code: "25", name: "Doubs")
        #expect(model.deptInfo?.name == "Doubs")
        #expect(model.deptInfo?.row == nil)
        model.clearDeptInfo()
        #expect(model.deptInfo == nil)
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

    @Test("Météo déjà reçue : une emprise contenue dans la dernière, même couche, ne redemande rien")
    func weatherCoverage() {
        let loaded = BBox(minLon: 6, minLat: 46, maxLon: 7, maxLat: 47)
        let inside = BBox(minLon: 6.2, minLat: 46.2, maxLon: 6.8, maxLat: 46.8)
        let overlapping = BBox(minLon: 5.9, minLat: 46.2, maxLon: 6.8, maxLat: 46.8)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cepes = LayerKey.group("cepes")
        let coverage = WeatherCoverage(bbox: loaded, layer: cepes, at: now)
        #expect(loaded.contains(inside) && loaded.contains(loaded) && !loaded.contains(overlapping))
        #expect(MapModel.weatherAlreadyCovers(coverage, layer: cepes, bbox: inside, now: now))
        #expect(MapModel.weatherAlreadyCovers(coverage, layer: cepes, bbox: loaded, now: now + 60))
        #expect(!MapModel.weatherAlreadyCovers(coverage, layer: cepes, bbox: overlapping, now: now))
        #expect(!MapModel.weatherAlreadyCovers(coverage, layer: .species("boletus_edulis"), bbox: inside, now: now))
        #expect(!MapModel.weatherAlreadyCovers(nil, layer: cepes, bbox: inside, now: now))
        let later = now + MapModel.weatherCoverageMaxAge + 1
        #expect(!MapModel.weatherAlreadyCovers(coverage, layer: cepes, bbox: inside, now: later))
    }
}
