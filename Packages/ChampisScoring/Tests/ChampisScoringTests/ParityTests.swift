import Foundation
import Testing
@testable import ChampisScoring

/// Rejoue `shared/vectors/*.json` (générés par Python, jamais écrits à la main) contre le portage
/// Swift : tolérance 1e-6 sur les scores, égalité stricte sur `label`, `hex`, `leading`
/// (skill `scoring-parity`).
private let tolerance = 1e-6

private struct TrapezoidJSON: Decodable {
    let min: Double
    let optLow: Double
    let optHigh: Double
    let max: Double
    enum CodingKeys: String, CodingKey { case min, optLow = "opt_low", optHigh = "opt_high", max }
    var trapezoid: Trapezoid { Trapezoid(min: min, optLow: optLow, optHigh: optHigh, max: max) }
}

private struct TrapezoidCase: Decodable {
    let x: Double
    let t: TrapezoidJSON
    let expected: Double
}

private struct PhiCase: Decodable {
    let species: String
    let date: String
    let altM: Double
    let expected: Double
    enum CodingKeys: String, CodingKey { case species, date, altM = "alt_m", expected }
}

private struct SeriesJSON: Decodable {
    let dates: [String]
    let tMean: [Double]
    let tMin: [Double]
    let tMax: [Double]
    let rain: [Double]
    let snow: [Double]
    let et0: [Double]
    let soilMoisturePct: [Double]
    /// Température du sol (facteur optionnel, 9 nov. 2026) : fournie dans tous les cas, lue par les espèces qui l'emploient.
    let soilTemp: [Double]?
    enum CodingKeys: String, CodingKey {
        case dates, rain, snow, et0
        case tMean = "t_mean", tMin = "t_min", tMax = "t_max", soilMoisturePct = "soil_moisture_pct"
        case soilTemp = "soil_temp"
    }
}

private struct MCase: Decodable {
    let species: String
    /// Fichier espèce embarqué dans le cas (un facteur qu'aucune espèce publiée n'emploie encore) :
    /// rejoué à la place de la ressource `species/<id>.json`.
    let speciesOverride: Species?
    let scenario: String
    let day: String
    let altM: Double
    let cellElevationM: Double
    let series: SeriesJSON
    let expected: [String: Double]  // temp, rain, trigger, soil_moisture, [soil_temp], frost, water_balance, heat, memory, M, M_eff
    enum CodingKeys: String, CodingKey {
        case species, scenario, day, series, expected
        case speciesOverride = "species_override"
        case altM = "alt_m", cellElevationM = "cell_elevation_m"
    }
}

private struct GroupCase: Decodable {
    let scores: [String: Double]
    let expected: GroupExpected
    struct GroupExpected: Decodable {
        let score: Double
        let leading: String?
    }
}

private struct PaletteCase: Decodable {
    let score: Double
    let expected: PaletteExpected
    struct PaletteExpected: Decodable {
        let label: String
        let hex: String
        /// Couleur du pixel (échelle linéaire, 6 nov. 2026) : `[r, g, b, a]` sur 8 bits.
        let rgba: [Int]
    }
}

private struct VectorFile<Case: Decodable>: Decodable {
    let cases: [Case]
}

private func resource(_ name: String, ext: String, subdirectory: String? = nil) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdirectory),
        "ressource \(name).\(ext) absente : lancer scripts/sync-vectors.sh"
    )
    return try Data(contentsOf: url)
}

/// Les vecteurs sont lus sans conversion de clés : les identifiants d'espèces (`boletus_edulis`)
/// et les noms de facteurs (`soil_moisture`, `M_eff`) sont des données, pas des propriétés.
private func vectors<Case: Decodable>(_ name: String, as type: Case.Type) throws -> [Case] {
    let data = try resource(name, ext: "json", subdirectory: "vectors")
    return try JSONDecoder().decode(VectorFile<Case>.self, from: data).cases
}

private func species(_ id: String) throws -> Species {
    try Species.decode(resource(id, ext: "json", subdirectory: "species"))
}

private func palette() throws -> Palette {
    try Palette.decode(resource("palette", ext: "json"))
}

private func close(_ a: Double, _ b: Double) -> Bool {
    abs(a - b) <= tolerance
}

struct ParityTests {
    @Test("Les clés snake_case des espèces sont lues telles quelles (décalage altitudinal compris)")
    func speciesKeys() throws {
        let sp = try species("cantharellus_pallens")
        let shift = try #require(sp.phenology.altitudeShift)
        #expect(shift.referenceM == 300 && shift.startDaysPer100m == 4 && shift.endDaysPer100m == -3 && shift.maxDays == 30)
        #expect(sp.weather.trigger.eventMm > 0 && sp.weather.frost.tminC < 5 && sp.weather.waterBalance.severeMm < 0)
        #expect(sp.weather.weights.soilMoisture > 0 && sp.weather.tempMean.c.optLow < sp.weather.tempMean.c.optHigh)
        // 12 novembre 2026 à 1 400 m : la saison, avancée de 30 jours, est finie → 0 (et non le plancher 0,25)
        #expect(try Phenology.window(sp, day: CivilDate(iso: "2026-11-12"), altM: 1400) == 0)
        let p = try palette()
        #expect(p.altEncoding.classM == 300 && p.tileEncoding.scale == 254 && p.nodataHex.hasPrefix("#"))
    }

    @Test("Trapèze : bornes exactes, ±ε, marche et falaise")
    func trapezoid() throws {
        let cases = try vectors("trapezoid", as: TrapezoidCase.self)
        #expect(cases.count >= 20)
        for c in cases {
            #expect(close(c.t.trapezoid.value(c.x), c.expected), "x=\(c.x) t=\(c.t.trapezoid)")
        }
    }

    @Test("Φ : toutes les espèces, trois altitudes, toute l'année, 29 février")
    func phi() throws {
        let cases = try vectors("phi", as: PhiCase.self)
        #expect(cases.count > 1000)
        var cache: [String: Species] = [:]
        for c in cases {
            if cache[c.species] == nil { cache[c.species] = try species(c.species) }
            let phi = try Phenology.window(cache[c.species]!, day: CivilDate(iso: c.date), altM: c.altM)
            #expect(close(phi, c.expected), "\(c.species) \(c.date) \(c.altM) m")
        }
    }

    @Test("M, M_eff et chaque facteur : scénarios météo de référence")
    func weatherIndex() throws {
        let cases = try vectors("m", as: MCase.self)
        #expect(cases.count >= 60)
        var overrides = 0
        for c in cases {
            let sp = try c.speciesOverride ?? species(c.species)
            if c.speciesOverride != nil { overrides += 1 }
            let s = try DailySeries(
                dates: c.series.dates.map { try CivilDate(iso: $0) },
                tMean: c.series.tMean, tMin: c.series.tMin, tMax: c.series.tMax,
                rain: c.series.rain, snow: c.series.snow, et0: c.series.et0,
                soilMoisturePct: c.series.soilMoisturePct, cellElevationM: c.cellElevationM,
                soilTemp: c.series.soilTemp
            )
            let f = try WeatherIndex.weatherIndex(sp, s, day: CivilDate(iso: c.day), altM: c.altM)
            for (name, expected) in c.expected {
                let actual = try #require(f[name], "facteur inconnu \(name)")
                #expect(close(actual, expected), "\(c.species) \(c.scenario) \(c.day) \(c.altM) m : \(name)")
            }
        }
        #expect(overrides >= 4, "les cas à fichier embarqué (soil_temp) sont dans m.json")
    }

    @Test("Température du sol : facteur optionnel, absent = poids 0 ; présent sans série = erreur")
    func soilTempIsOptional() throws {
        let plain = try species("boletus_edulis")
        #expect(plain.weather.soilTemp == nil && plain.weather.weights.soilTemp == 0)
        let start = try CivilDate(iso: "2026-05-01")
        let n = 170
        func series(_ soilTemp: [Double]?) throws -> DailySeries {
            try DailySeries(
                dates: (0..<n).map { start.adding(days: $0) },
                tMean: Array(repeating: 13, count: n), tMin: Array(repeating: 8, count: n),
                tMax: Array(repeating: 18, count: n), rain: Array(repeating: 2.5, count: n),
                snow: Array(repeating: 0, count: n), et0: Array(repeating: 1.5, count: n),
                soilMoisturePct: Array(repeating: 0.6, count: n), cellElevationM: 700,
                soilTemp: soilTemp
            )
        }
        let day = start.adding(days: n - 1)
        let without = try WeatherIndex.weatherIndexRaw(plain, series(nil), day: day, altM: 700)
        let with = try WeatherIndex.weatherIndexRaw(plain, series(Array(repeating: 3, count: n)), day: day, altM: 700)
        #expect(without.soilTemp == nil && without == with)
        // le même cèpe avec le bloc : rejoué depuis les cas à fichier embarqué de m.json
        let cases = try vectors("m", as: MCase.self)
        let sp = try #require(cases.compactMap(\.speciesOverride).first)
        #expect(sp.weather.weights.soilTemp > 0 && sp.weather.soilTemp != nil)
        #expect(throws: ScoringError.missingSeries("soil_temperature_0_to_7cm_mean")) {
            try WeatherIndex.weatherIndexRaw(sp, series(nil), day: day, altM: 700)
        }
        let f = try WeatherIndex.weatherIndexRaw(sp, series(Array(repeating: 11, count: n)), day: day, altM: 700)
        #expect(f.soilTemp == 1.0)
    }

    @Test("Groupe : max des espèces, première par ordre alphabétique à égalité")
    func group() throws {
        for c in try vectors("group", as: GroupCase.self) {
            let g = GroupScore(scores: c.scores)
            #expect(close(g.score, c.expected.score))
            #expect(g.leading == c.expected.leading)
        }
    }

    @Test("Palette : seuils exacts 0,15 / 0,35 / 0,55 / 0,75, et couleur du pixel (alpha = score, floor(x + 0,5))")
    func paletteClasses() throws {
        let p = try palette()
        let cases = try vectors("palette", as: PaletteCase.self)
        #expect(cases.count >= 20)
        for c in cases {
            let cls = p.classify(c.score)
            #expect(cls.label == c.expected.label && cls.hex == c.expected.hex, "score \(c.score)")
            let px = try #require(p.pixelColor(c.score), "score \(c.score)")
            #expect([Int(px.r), Int(px.g), Int(px.b), Int(px.a)] == c.expected.rgba, "score \(c.score)")
        }
    }

    @Test("Palette sans échelle (API antérieure au 6 nov. 2026) : pas de couleur de pixel, les mots restent")
    func paletteWithoutScale() throws {
        let json = """
        {
          "version": 1,
          "thresholds": [
            { "min": 0.55, "label": "bon", "fr": "Bon", "hex": "#4CA64C" },
            { "min": 0.0, "label": "tres_faible", "fr": "Très faible", "hex": "#B8402E" }
          ],
          "nodata_hex": "#00000000",
          "tile_encoding": { "channel": "luminance", "scale": 254, "nodata": 255 },
          "alt_encoding": { "channel": "luminance", "class_m": 300, "nodata": 255 }
        }
        """
        let p = try Palette.decode(Data(json.utf8))
        #expect(p.scale == nil)
        #expect(p.pixelColor(0.8) == nil)
        #expect(p.classify(0.8).label == "bon" && p.classify(0.1).label == "tres_faible")
        // Un hex invalide dans l'échelle : pas de couleur non plus, jamais une couleur inventée
        let bad = Palette.Scale(hex: "#zzzzzz", alphaMin: 0, alphaMax: 1)
        #expect(bad.rgb == nil)
        #expect(bad.alpha8(for: 0.5) == 128)
    }

    @Test("Dates civiles : ordinal, jour de l'année, arithmétique, années bissextiles")
    func civilDates() throws {
        let d = try CivilDate(iso: "2026-10-30")
        #expect(d.dayOfYear == 303 && d.adding(days: 63).description == "2027-01-01")
        #expect(try CivilDate(iso: "2024-03-01").days(since: CivilDate(iso: "2024-02-28")) == 2)
        #expect(CivilDate(ordinal: d.ordinal) == d)
        #expect(CivilDate.dayOfYear(month: 2, day: 29, year: 2026) == 59)  // 29 février → 28
        #expect(roundHalfUp(2.5) == 3 && roundHalfUp(-2.5) == -2 && roundHalfUp(2.49) == 2)
        #expect(altitudeClass(0) == 150 && altitudeClass(299) == 150 && altitudeClass(300) == 450)
        #expect(throws: ScoringError.self) { try CivilDate(iso: "2026-02-30") }
    }

    @Test("Saison à cheval sur le 1er janvier : le pied bleu court du 15 août au 31 janvier")
    func seasonAcrossNewYear() throws {
        let nuda = try species("lepista_nuda")
        let edulis = try species("boletus_edulis")
        #expect(try Phenology.seasonWraps(nuda.phenology) && !Phenology.seasonWraps(edulis.phenology))
        let ref = try #require(nuda.phenology.altitudeShift).referenceM
        #expect(try Phenology.window(nuda, day: CivilDate(iso: "2026-11-01"), altM: ref) == 1.0)
        #expect(try Phenology.window(nuda, day: CivilDate(iso: "2027-01-01"), altM: ref) == Phenology.phiFloor)
        #expect(try Phenology.window(nuda, day: CivilDate(iso: "2027-01-31"), altM: ref) == Phenology.phiFloor)
        #expect(try Phenology.window(nuda, day: CivilDate(iso: "2027-02-01"), altM: ref) == 0)
        #expect(try Phenology.window(nuda, day: CivilDate(iso: "2027-01-01"), altM: 1100) == 0)  // fin avancée de 32 j
        #expect(try Phenology.window(nuda, day: CivilDate(iso: "2028-02-29"), altM: ref) == 0)
        #expect(try Phenology.window(edulis, day: CivilDate(iso: "2027-01-01"), altM: 0) == 0)  // année civile : inchangé
    }

    @Test("Une série trop courte est une erreur, jamais une approximation")
    func shortSeriesThrows() throws {
        let sp = try species("boletus_edulis")
        let start = try CivilDate(iso: "2026-10-01")
        let n = 20
        let s = try DailySeries(
            dates: (0..<n).map { start.adding(days: $0) },
            tMean: Array(repeating: 13, count: n), tMin: Array(repeating: 8, count: n),
            tMax: Array(repeating: 18, count: n), rain: Array(repeating: 2.5, count: n),
            snow: Array(repeating: 0, count: n), et0: Array(repeating: 1.5, count: n),
            soilMoisturePct: Array(repeating: 0.6, count: n), cellElevationM: 700
        )
        #expect(throws: ScoringError.self) {
            try WeatherIndex.weatherIndex(sp, s, day: start.adding(days: n - 1), altM: 700)
        }
        #expect(sp.requiredSeriesDays == 130)
    }
}
