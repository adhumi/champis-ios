import ChampisScoring
import Foundation
import Testing
@testable import Champis

struct WeatherFieldTests {
    static func field() throws -> WeatherField {
        var field = WeatherField()
        field.merge(try Fixtures.decode(WeatherBBoxResponse.self, Fixtures.weatherJSON))
        return field
    }

    static func altEncoding() throws -> Palette.AltEncoding {
        try Palette.decode(Data(Fixtures.paletteJSON.utf8)).altEncoding
    }

    @Test("Fusion : cellule, espèces, jours ; cellule la plus proche")
    func merge() throws {
        let field = try Self.field()
        #expect(field.today == "2026-10-30")
        #expect(field.cells.count == 1)
        #expect(!field.anyStale)
        #expect(field.unavailable == ["c_9"])

        let cell = try #require(field.nearestCell(lat: 47.1, lon: 8.3))
        #expect(cell.info.id == "c_1")
        #expect(cell.row(species: "boletus_edulis", date: "2026-10-31", altKey: "150")?.mEff == 0.6)
        #expect(cell.row(species: "boletus_edulis", date: "2026-11-30", altKey: "150") == nil)
        #expect(cell.row(species: "inconnue", date: "2026-10-30", altKey: "150") == nil)
        #expect(WeatherField().nearestCell(lat: 47, lon: 8) == nil)
    }

    @Test("Une seconde emprise complète la première sans l'effacer")
    func mergeKeepsOtherCells() throws {
        var field = try Self.field()
        let second = Fixtures.weatherJSON
            .replacingOccurrences(of: "\"id\": \"c_1\"", with: "\"id\": \"c_2\"")
            .replacingOccurrences(of: "\"lat\": 47.0", with: "\"lat\": 47.5")
        field.merge(try Fixtures.decode(WeatherBBoxResponse.self, second))
        #expect(field.cells.count == 2)
        #expect(field.nearestCell(lat: 47.6, lon: 8.4)?.info.id == "c_2")
        #expect(field.nearestCell(lat: 46.9, lon: 8.4)?.info.id == "c_1")
    }

    @Test("Nouveau jour côté API : la météo précédente est jetée (les dates ne se recouvrent plus)")
    func newDay() throws {
        var field = try Self.field()
        let tomorrow = Fixtures.weatherJSON
            .replacingOccurrences(of: "\"today\": \"2026-10-30\"", with: "\"today\": \"2026-10-31\"")
            .replacingOccurrences(of: "\"id\": \"c_1\"", with: "\"id\": \"c_2\"")
        field.merge(try Fixtures.decode(WeatherBBoxResponse.self, tomorrow))
        #expect(field.today == "2026-10-31")
        #expect(field.cells.count == 1)
        #expect(field.cells["c_1"] == nil)
    }

    @Test("Classe d'altitude du pixel : couche A, repli médiane cellule, inconnu → nil")
    func altKey() throws {
        let field = try Self.field()
        let cell = try #require(field.cells["c_1"])
        let encoding = try Self.altEncoding()

        let fromLayer = cell.altKey(classIndex: 1, encoding: encoding)
        #expect(fromLayer?.key == "450")
        #expect(fromLayer?.fallback == false)
        #expect(cell.altKey(classIndex: 0, encoding: encoding)?.key == "150")
        // 1 350 m : pas de classe calculée si haut, la plus proche est prise
        #expect(cell.altKey(classIndex: 4, encoding: encoding)?.key == "450")

        // Sans couche A : altitude médiane 620 m → cible 750 → classe 450, marquée repli
        let fallback = cell.altKey(classIndex: nil, encoding: encoding)
        #expect(fallback?.key == "450")
        #expect(fallback?.fallback == true)
        #expect(cell.altKey(classIndex: encoding.nodata, encoding: encoding)?.fallback == true)

        let unknown = WeatherField.Cell(
            info: WeatherCellInfo(id: "x", lat: 0, lon: 0, altClasses: [150], elevationM: nil), stale: false, rows: [:]
        )
        #expect(unknown.altKey(classIndex: nil, encoding: encoding) == nil)
        #expect(unknown.altKey(classIndex: 2, encoding: encoding)?.key == "150")
        #expect(WeatherField.Cell.key(forCenter: 150.0) == "150")
    }
}
