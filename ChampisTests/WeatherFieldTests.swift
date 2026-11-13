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

    static func compact() throws -> WeatherFieldResponse {
        try Fixtures.decode(WeatherFieldResponse.self, Fixtures.weatherFieldJSON)
    }

    /// Quatre cellules de la grille autour de 47,1234 N 6,3187 E, avec les valeurs du premier cas
    /// de `interp.json` (classe 150 m, 30 octobre) ; `skipping` en retire, `unavailable` liste des
    /// cellules sans météo comme le fait `/weather/bbox`.
    static func gridField(skipping skipped: Set<String> = [], unavailable: [String] = []) throws -> WeatherField {
        let values = ["c_0945_6670": 0.8, "c_0950_6670": 0.1, "c_0945_6675": 0.4, "c_0950_6675": 0.6]
        let cells = values.keys.sorted().filter { !skipped.contains($0) }.map { id in
            """
            { "id": "\(id)", "lat": 47.12, "lon": 6.32, "elevation_m": 150.0, "alt_classes": [150.0],
              "f": { "boletus_edulis": { "150": \(values[id] ?? 0) } } }
            """
        }.joined(separator: ",")
        let listed = unavailable.map { "\"\($0)\"" }.joined(separator: ",")
        let bbox = """
        { "today": "2026-10-30", "computed_at": "2026-10-30T03:12:00+00:00", "scoring_version": "1.0.0",
          "cells": [], "unavailable": [\(listed)], "retry_after": null }
        """
        let compact = """
        { "today": "2026-10-30", "computed_at": "2026-10-30T03:12:00+00:00", "day": "2026-10-30",
          "scoring_version": "1.0.0", "cells": [\(cells)], "unavailable": 0 }
        """
        var field = WeatherField()
        field.merge(try Fixtures.decode(WeatherBBoxResponse.self, bbox))
        field.merge(try Fixtures.decode(WeatherFieldResponse.self, compact))
        return field
    }

    static func altEncoding() throws -> Palette.AltEncoding {
        try Palette.decode(Data(Fixtures.paletteJSON.utf8)).altEncoding
    }

    @Test("Fusion : cellule, espèces, jours ; cellule la plus proche à moins de 7,5 km")
    func merge() throws {
        let field = try Self.field()
        #expect(field.today == "2026-10-30")
        #expect(field.cells.count == 1)
        #expect(field.index.count == 1)
        #expect(!field.anyStale)
        #expect(field.unavailable == ["c_9"])

        // 47,03 N / 8,35 E : 5 km de c_1
        let cell = try #require(field.nearestCell(lat: 47.03, lon: 8.35))
        #expect(cell.info.id == "c_1")
        #expect(cell.row(species: "boletus_edulis", date: "2026-10-31", altKey: "150")?.mEff == 0.6)
        #expect(cell.factor(species: "boletus_edulis", date: "2026-10-30", altKey: "450") == 0.9)
        #expect(cell.row(species: "boletus_edulis", date: "2026-11-30", altKey: "150") == nil)
        #expect(cell.factor(species: "boletus_edulis", date: "2026-11-30", altKey: "150") == nil)
        #expect(cell.row(species: "inconnue", date: "2026-10-30", altKey: "150") == nil)
        // 47,1 N : 11 km de c_1, au-delà de la borne → pas de météo, jamais celle d'une cellule lointaine
        #expect(field.nearestCell(lat: 47.1, lon: 8.3) == nil)
        #expect(WeatherField().nearestCell(lat: 47, lon: 8) == nil)
    }

    @Test("Une seconde emprise complète la première sans l'effacer")
    func mergeKeepsOtherCells() throws {
        var field = try Self.field()
        let second = Fixtures.weatherJSON
            .replacingOccurrences(of: "\"id\": \"c_1\"", with: "\"id\": \"c_2\"")
            .replacingOccurrences(of: "\"lat\": 47.0", with: "\"lat\": 47.1")
        field.merge(try Fixtures.decode(WeatherBBoxResponse.self, second))
        #expect(field.cells.count == 2)
        #expect(field.index.count == 2)
        #expect(field.nearestCell(lat: 47.08, lon: 8.4)?.info.id == "c_2")
        #expect(field.nearestCell(lat: 47.02, lon: 8.4)?.info.id == "c_1")
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
        #expect(field.index.count == 1)
    }

    @Test("Champ compact : f = M_eff × Φ du jour, par espèce et classe, sans ligne complète ; stale et cellules gardés")
    func mergeField() throws {
        var field = WeatherField()
        field.merge(try Self.compact())
        #expect(field.today == "2026-10-30")
        #expect(field.cells.count == 2)
        #expect(field.index.count == 2)
        #expect(field.anyStale)
        #expect(field.unavailable.isEmpty)  // le champ ne donne qu'un nombre, le statut le dit

        let c1 = try #require(field.cells["c_1"])
        #expect(c1.info.elevationM == 620 && c1.info.altClasses == [150, 450])
        #expect(!c1.stale)
        #expect(c1.factor(species: "boletus_edulis", date: "2026-10-30", altKey: "450") == 0.9)
        #expect(c1.factor(species: "boletus_edulis", date: "2026-10-30", altKey: "150") == 0.5)
        #expect(c1.factor(species: "boletus_aereus", date: "2026-10-30", altKey: "150") == 0.2)
        #expect(c1.row(species: "boletus_edulis", date: "2026-10-30", altKey: "450") == nil)  // M_eff et Φ : GET /weather
        #expect(c1.factor(species: "boletus_edulis", date: "2026-10-31", altKey: "450") == nil)  // un seul jour

        let c3 = try #require(field.cells["c_3"])
        #expect(c3.stale)
        #expect(c3.factor(species: "boletus_edulis", date: "2026-10-30", altKey: "150") == 0.79)
        #expect(field.nearestCell(lat: 47.52, lon: 8.4)?.info.id == "c_3")
        #expect(field.nearestCell(lat: 47.25, lon: 8.4) == nil)  // à mi-chemin : 28 km de chaque
    }

    @Test("Champs de plusieurs jours : chaque jour s'ajoute, la même cellule garde les autres")
    func mergeFieldByDay() throws {
        var field = WeatherField()
        field.merge(try Self.compact())
        let tomorrow = Fixtures.weatherFieldJSON
            .replacingOccurrences(of: "\"day\": \"2026-10-30\"", with: "\"day\": \"2026-10-31\"")
            .replacingOccurrences(of: "\"450\": 0.9", with: "\"450\": 0.6")
        field.merge(try Fixtures.decode(WeatherFieldResponse.self, tomorrow))
        #expect(field.cells.count == 2)
        let c1 = try #require(field.cells["c_1"])
        #expect(c1.factor(species: "boletus_edulis", date: "2026-10-30", altKey: "450") == 0.9)
        #expect(c1.factor(species: "boletus_edulis", date: "2026-10-31", altKey: "450") == 0.6)
        #expect(c1.factor(species: "boletus_edulis", date: "2026-10-31", altKey: "150") == 0.5)

        // minuit passé côté API : tout est jeté
        let newDay = Fixtures.weatherFieldJSON
            .replacingOccurrences(of: "\"today\": \"2026-10-30\"", with: "\"today\": \"2026-10-31\"")
        field.merge(try Fixtures.decode(WeatherFieldResponse.self, newDay))
        #expect(field.today == "2026-10-31")
        #expect(field.cells["c_1"]?.factor(species: "boletus_edulis", date: "2026-10-31", altKey: "450") == nil)
    }

    @Test("Bbox puis champ, champ puis bbox : une seule forme, la ligne complète gardée quand le facteur concorde")
    func mergeBothSources() throws {
        var field = try Self.field()
        field.merge(try Self.compact())
        let c1 = try #require(field.cells["c_1"])
        #expect(c1.factor(species: "boletus_edulis", date: "2026-10-30", altKey: "450") == 0.9)
        #expect(c1.row(species: "boletus_edulis", date: "2026-10-30", altKey: "450")?.phi == 1.0)  // même facteur : gardée
        #expect(c1.row(species: "boletus_edulis", date: "2026-10-31", altKey: "150")?.mEff == 0.6)  // l'autre jour reste
        #expect(field.cells["c_3"] != nil)

        var reversed = WeatherField()
        reversed.merge(try Self.compact())
        reversed.merge(try Fixtures.decode(WeatherBBoxResponse.self, Fixtures.weatherJSON))
        let r1 = try #require(reversed.cells["c_1"])
        #expect(r1.row(species: "boletus_edulis", date: "2026-10-30", altKey: "450")?.mEff == 0.9)
        #expect(r1.factor(species: "boletus_aereus", date: "2026-10-30", altKey: "150") == 0.2)
        #expect(reversed.cells["c_3"]?.stale == true)

        // un facteur qui a changé entre les deux sources (nouvelle pré-chauffe) : la ligne ne ment pas
        var changed = try Self.field()
        let other = Fixtures.weatherFieldJSON.replacingOccurrences(of: "\"450\": 0.9", with: "\"450\": 0.8")
        changed.merge(try Fixtures.decode(WeatherFieldResponse.self, other))
        let x1 = try #require(changed.cells["c_1"])
        #expect(x1.factor(species: "boletus_edulis", date: "2026-10-30", altKey: "450") == 0.8)
        #expect(x1.row(species: "boletus_edulis", date: "2026-10-30", altKey: "450") == nil)
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
            info: WeatherCellInfo(id: "x", lat: 0, lon: 0, altClasses: [150], elevationM: nil), stale: false
        )
        #expect(unknown.altKey(classIndex: nil, encoding: encoding) == nil)
        #expect(unknown.altKey(classIndex: 2, encoding: encoding)?.key == "150")
        #expect(WeatherField.Cell.key(forCenter: 150.0) == "150")
    }

    @Test("Interpolation entre cellules : la valeur du vecteur de parité, à plat sans voisine chargée")
    func interpolation() throws {
        let encoding = try Self.altEncoding()
        let all = try Self.gridField()
        let sample = try #require(all.sample(lat: 47.1234, lon: 6.3187))
        #expect(sample.home.info.id == "c_0950_6670")
        #expect(sample.isInterpolated)
        let value = try #require(
            sample.factor(species: "boletus_edulis", date: "2026-10-30", classIndex: nil, encoding: encoding)
        )
        #expect(abs(value - 0.367743328) < 1e-6)
        // jour ou espèce que la cellule du point n'a pas : rien
        #expect(sample.factor(species: "boletus_edulis", date: "2026-10-31", classIndex: nil, encoding: encoding) == nil)
        #expect(sample.factor(species: "boletus_aereus", date: "2026-10-30", classIndex: nil, encoding: encoding) == nil)

        let alone = try Self.gridField(skipping: ["c_0945_6670", "c_0945_6675", "c_0950_6675"])
        let lone = try #require(alone.sample(lat: 47.1234, lon: 6.3187))
        #expect(!lone.isInterpolated)
        let flat = try #require(
            lone.factor(species: "boletus_edulis", date: "2026-10-30", classIndex: nil, encoding: encoding)
        )
        #expect(abs(flat - 0.1) < 1e-9)
    }

    @Test("Cellule listée sans météo : rien, jamais la voisine ; hors grille : la plus proche, sans interpolation")
    func cellWithoutWeather() throws {
        let closed = try Self.gridField(skipping: ["c_0950_6670"], unavailable: ["c_0950_6670"])
        let found = closed.sample(lat: 47.1234, lon: 6.3187) != nil
        #expect(!found)
        let offGrid = try Self.gridField(skipping: ["c_0950_6670"])
        let near = try #require(offGrid.sample(lat: 47.1234, lon: 6.3187))
        #expect(near.corners.isEmpty && !near.isInterpolated)
        // une réponse ultérieure qui donne la cellule lève l'indisponibilité
        let back = try Self.gridField(unavailable: ["c_0950_6670"])
        #expect(back.sample(lat: 47.1234, lon: 6.3187)?.home.info.id == "c_0950_6670")
    }

    /// La palette de test avec l'encodage de la couche E (pas de 20 m), comme le référentiel
    /// depuis le 13 nov. 2026.
    static func finePalette() throws -> Palette {
        let json = Fixtures.paletteJSON.replacingOccurrences(
            of: "\"alt_encoding\"",
            with: "\"elev_encoding\": { \"channel\": \"luminance\", \"step_m\": 20, \"nodata\": 255 }, \"alt_encoding\""
        )
        return try Palette.decode(Data(json.utf8))
    }

    @Test("Couche E : M_eff × Φ interpolé entre les deux classes qui encadrent l'altitude du pixel")
    func betweenAltitudeClasses() throws {
        let fine = try Self.finePalette()
        #expect(fine.elevEncoding?.stepM == 20)
        let coarse = try Palette.decode(Data(Fixtures.paletteJSON.utf8))
        #expect(coarse.elevEncoding == nil)
        // c_1 : classes 150 (0,5) et 450 (0,9) le 30 octobre, altitude médiane 620 m
        let field = try Self.field()
        let cell = try #require(field.cells["c_1"])
        func at(_ k: Int?, _ palette: Palette) -> Double? {
            cell.factor(species: "boletus_edulis", date: "2026-10-30", index: k, palette: palette)
        }
        // tranche 14 = 290 m, entre 150 et 450
        let mid = try #require(at(14, fine))
        #expect(abs(mid - (0.5 + (290.0 - 150.0) / 300.0 * 0.4)) < 1e-9)
        // tranche 22 = 450 m : la valeur de la classe ; au-delà et en deçà : à plat
        let centre = try #require(at(22, fine))
        #expect(abs(centre - 0.9) < 1e-9)
        let high = try #require(at(100, fine))
        let low = try #require(at(0, fine))
        #expect(abs(high - 0.9) < 1e-9 && abs(low - 0.5) < 1e-9)
        // altitude inconnue : classe de l'altitude médiane de la cellule (450), avec ou sans couche E
        let unknownFine = try #require(at(nil, fine))
        let unknownCoarse = try #require(at(nil, coarse))
        #expect(unknownFine == 0.9 && unknownCoarse == 0.9)
        // sans encodage E, l'indice est une classe de 300 m : 0 → 150 m
        let classZero = try #require(at(0, coarse))
        #expect(classZero == 0.5)
        #expect(at(14, fine) != nil && cell.factor(species: "boletus_edulis", date: "2026-11-02", altitude: 290) == nil)
    }
}
