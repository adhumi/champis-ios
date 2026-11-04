import Foundation
import Testing
@testable import ChampisScoring

/// Gel en rampe (spec › Scoring › gel en rampe, 4 nov. 2026), en miroir de `api/tests/test_scoring.py` :
/// mêmes séries, mêmes valeurs attendues, tolérance 1e-6. Les paramètres du cèpe de Bordeaux
/// (tmin_c −2, ramp_c 2, nights 2, factor 0,2) sont lus dans les ressources, jamais écrits ici.
private let tolerance = 1e-6

private func close(_ a: Double, _ b: Double, _ tol: Double = tolerance) -> Bool {
    abs(a - b) <= tol
}

private func speciesData(_ id: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: id, withExtension: "json", subdirectory: "species"),
        "ressource \(id).json absente : lancer scripts/sync-vectors.sh"
    )
    return try Data(contentsOf: url)
}

private func edulis() throws -> Species {
    try Species.decode(speciesData("boletus_edulis"))
}

/// Série constante (`make_series` de conftest.py) : 13 °C, tmin 8 °C, 2,5 mm/j, cellule à 700 m,
/// avec des retouches par indice sur `tMin` et `rain`.
private func series(
    start: CivilDate, n: Int, tMin: [Int: Double] = [:], rain: [Int: Double] = [:]
) throws -> DailySeries {
    var tMinValues = Array(repeating: 8.0, count: n)
    for (i, v) in tMin { tMinValues[i] = v }
    var rainValues = Array(repeating: 2.5, count: n)
    for (i, v) in rain { rainValues[i] = v }
    return try DailySeries(
        dates: (0..<n).map { start.adding(days: $0) },
        tMean: Array(repeating: 13, count: n), tMin: tMinValues,
        tMax: Array(repeating: 18, count: n), rain: rainValues,
        snow: Array(repeating: 0, count: n), et0: Array(repeating: 1.5, count: n),
        soilMoisturePct: Array(repeating: 0.6, count: n), cellElevationM: 700
    )
}

/// `frost_series` : nuits douces (8 °C) sauf `nights` : {jours avant J : tmin}, J = 20 oct. 2026,
/// série de 30 jours depuis le 1er octobre, cellule et pixel à 700 m (pas de correction).
private func frostSeries(_ nights: [Int: Double]) throws -> (DailySeries, CivilDate) {
    let start = try CivilDate(iso: "2026-10-01")
    let day = try CivilDate(iso: "2026-10-20")
    let at = day.days(since: start)
    var tMin: [Int: Double] = [:]
    for (k, v) in nights { tMin[at - k] = v }
    let s = try series(start: start, n: 30, tMin: tMin)
    return (s, day)
}

private func frost(_ sp: Species, _ nights: [Int: Double]) throws -> Double {
    let (s, day) = try frostSeries(nights)
    return try WeatherIndex.factorFrost(sp, s, day, 700)
}

struct FrostRampTests {
    @Test("Les sept espèces ont une rampe de 2 °C, obligatoire et > 0")
    func rampCDecoded() throws {
        for id in [
            "boletus_aereus", "boletus_edulis", "boletus_pinophilus", "boletus_reticulatus",
            "cantharellus_alborufescens", "cantharellus_cibarius", "cantharellus_pallens",
        ] {
            let sp = try Species.decode(speciesData(id))
            #expect(sp.weather.frost.rampC > 0, id)
            #expect(sp.weather.frost.nights >= 1, id)
        }
        let sp = try edulis()
        #expect(sp.weather.frost.tminC == -2 && sp.weather.frost.rampC == 2)
        #expect(sp.weather.frost.nights == 2 && sp.weather.frost.factor == 0.2)
    }

    @Test("Une espèce sans ramp_c ne se décode pas : jamais une marche par défaut")
    func rampCRequired() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: speciesData("boletus_edulis")) as? [String: Any])
        var weather = try #require(json["weather"] as? [String: Any])
        var frostCfg = try #require(weather["frost"] as? [String: Any])
        #expect(frostCfg["ramp_c"] != nil)
        frostCfg["ramp_c"] = nil
        weather["frost"] = frostCfg
        json["weather"] = weather
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) { try Species.decode(data) }
    }

    @Test(
        "Sévérité d'une nuit : s = 1 − trapèze(tmin, tmin_c, tmin_c + ramp_c, +∞, +∞)",
        arguments: [
            (-5.0, 1.0), (-1e-9, 1.0), (0.0, 1.0), (0.5, 0.75), (1.0, 0.5), (1.5, 0.25),
            (2.0, 0.0), (2.0 + 1e-9, 0.0), (7.0, 0.0),
        ]
    )
    func severity(offsetC: Double, expected: Double) throws {
        let cfg = try edulis().weather.frost
        #expect(close(WeatherIndex.frostSeverity(cfg.tminC + offsetC, cfg), expected), "offset \(offsetC)")
    }

    @Test("Trapèze à bornes hautes infinies : plateau dès opt_low, pas de rampe descendante")
    func infiniteTrapezoid() {
        let t = Trapezoid(min: -2, optLow: 0, optHigh: .infinity, max: .infinity)
        #expect(t.value(-3) == 0 && t.value(-2) == 0 && close(t.value(-1), 0.5))
        #expect(t.value(0) == 1 && t.value(40) == 1 && t.value(1e300) == 1)
    }

    @Test("Cèpe : valeurs exactes de la rampe (test_frost_ramp_exact_values)")
    func exactValues() throws {
        let sp = try edulis()
        // aucune nuit froide
        #expect(try frost(sp, [:]) == 1.0)
        // une nuit à mi-rampe (−1 °C, s = 0,5) : 1 − 0,8 × 0,25 = 0,8
        #expect(try close(frost(sp, [0: -1.0]), 0.8))
        // une nuit pleine : 1 − 0,8 × 0,5 = 0,6
        #expect(try close(frost(sp, [3: -2.0]), 0.6))
        // deux nuits pleines : × factor, comme l'ancienne marche
        #expect(try close(frost(sp, [0: -2.0, 1: -2.0]), 0.2))
        // quatre nuits partielles qui se cumulent : S = 0,5 + 0,25 + 0,75 + 0 = 1,5 → 1 − 0,8 × 0,75
        #expect(try close(frost(sp, [0: -1.0, 1: -0.5, 2: -1.5, 3: 0.0]), 0.4))
        // S plafonné à nights : sept nuits polaires ne font pas moins que factor
        #expect(try close(frost(sp, Dictionary(uniqueKeysWithValues: (0..<7).map { ($0, -15.0) })), 0.2))
    }

    @Test("Continuité : plus de marche, en température comme en nombre de nuits")
    func continuity() throws {
        let sp = try edulis()
        let cfg = sp.weather.frost
        let top = cfg.tminC + cfg.rampC
        #expect(try close(frost(sp, [0: top - 1e-6]), 1.0))
        #expect(try frost(sp, [0: top]) == 1.0)
        #expect(try close(frost(sp, [0: cfg.tminC - 1e-6]), frost(sp, [0: cfg.tminC])))
        let values = try [1.0, 0.0, -0.5, -1.0, -1.5, -2.0, -3.0].map { try frost(sp, [0: $0]) }
        #expect(values == values.sorted(by: >))
    }

    @Test("Bord de fenêtre : J−window_days est dehors, J−window_days+1 dedans")
    func windowEdge() throws {
        let sp = try edulis()
        let cfg = sp.weather.frost
        let w = cfg.windowDays
        let expected = 1.0 - (1.0 - cfg.factor) / Double(cfg.nights)
        #expect(try close(frost(sp, [w: -10.0, w - 1: -10.0]), expected))
    }

    @Test("Altitude : tmin 2 °C à 700 m, −2,5 °C à 1 450 m → × factor, comme avant")
    func altitudeCorrection() throws {
        let sp = try edulis()
        let start = try CivilDate(iso: "2026-10-01")
        let day = try CivilDate(iso: "2026-10-20")
        let s = try series(start: start, n: 30, tMin: Dictionary(uniqueKeysWithValues: (0..<30).map { ($0, 2.0) }))
        #expect(try WeatherIndex.factorFrost(sp, s, day, 700) == 1.0)
        #expect(try close(WeatherIndex.factorFrost(sp, s, day, 1450), sp.weather.frost.factor))
    }

    @Test("Le facteur du jour, en rampe, multiplie aussi M_eff (règle 3)")
    func reappliedOnMEff() throws {
        let sp = try edulis()
        let start = try CivilDate(iso: "2026-03-01")
        let day = try CivilDate(iso: "2026-10-13")
        let rainDay = try CivilDate(iso: "2026-10-01").days(since: start)
        let mild = try WeatherIndex.weatherIndex(
            sp, series(start: start, n: 260, rain: [rainDay: 30.0]), day: day, altM: 700
        )
        // mi-rampe (−1 °C) la nuit de J seulement → 0,8
        let s = try series(start: start, n: 260, tMin: [day.days(since: start): -1.0], rain: [rainDay: 30.0])
        let r = try WeatherIndex.weatherIndex(sp, s, day: day, altM: 700)
        #expect(close(r.frost, 0.8))
        #expect(close(r.m, mild.m * 0.8))
        let days = sp.weather.persistence.days
        var bestPast = 0.0
        for k in 1...days {
            let past = try WeatherIndex.weatherIndexRaw(sp, s, day: day.adding(days: -k), altM: 700).m
            bestPast = Swift.max(bestPast, past * (1.0 - Double(k) / Double(days)))
        }
        let mEff = try #require(r.mEff)
        let mildEff = try #require(mild.mEff)
        #expect(close(mEff, Swift.min(1.0, Swift.max(r.m, bestPast) * 0.8)))
        #expect(mEff < mildEff)
    }
}
