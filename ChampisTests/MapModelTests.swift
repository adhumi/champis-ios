import Foundation
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
    }

    @Test("Date affichée : à partir du today de l'API")
    func format() {
        #expect(!MapModel.format(iso: "2026-10-30").isEmpty)
        #expect(MapModel.format(iso: "2026-10-30") != "2026-10-30")
        #expect(MapModel.format(iso: "n'importe quoi") == "n'importe quoi")
    }

    @Test("Statut météo : cellules, cache périmé, cellules manquantes")
    func status() throws {
        let response = try Fixtures.decode(WeatherBBoxResponse.self, Fixtures.weatherJSON)
        let status = MapModel.status(for: response)
        #expect(status.hasPrefix("1 cellule(s) météo"))
        #expect(status.contains("1 sans météo"))
        #expect(!status.contains("périmé"))
    }
}
