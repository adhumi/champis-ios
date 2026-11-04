/// Indice météo `M`, persistance `M_eff` et détail des facteurs, dans l'ordre exact de
/// `champis_api.scoring` : somme pondérée (temp, rain, trigger, soil), puis facteurs multiplicatifs
/// frost, water_balance, heat, memory, puis persistance, puis frost et water_balance réappliqués.
public struct WeatherFactors: Hashable, Sendable {
    public var temp: Double
    public var rain: Double
    public var trigger: Double
    public var soilMoisture: Double
    public var frost: Double
    public var waterBalance: Double
    public var heat: Double
    public var memory: Double
    public var m: Double
    /// Renseigné par `weatherIndex`, nul après `weatherIndexRaw`.
    public var mEff: Double?

    /// Accès par le nom des facteurs tel que l'API les nomme (`factors` de `/weather`).
    public subscript(name: String) -> Double? {
        switch name {
        case "temp": temp
        case "rain": rain
        case "trigger": trigger
        case "soil_moisture": soilMoisture
        case "frost": frost
        case "water_balance": waterBalance
        case "heat": heat
        case "memory": memory
        case "M": m
        case "M_eff": mEff
        default: nil
        }
    }
}

public enum WeatherIndex {
    /// −0,6 °C par 100 m.
    public static let lapseRateCPerM = 0.006
    public static let soilWindowDays = 7

    static func corrected(_ values: ArraySlice<Double>, series: DailySeries, altM: Double) -> [Double] {
        let delta = -lapseRateCPerM * (altM - series.cellElevationM)
        return values.map { $0 + delta }
    }

    static func mean(_ values: [Double]) -> Double {
        values.sumInOrder() / Double(values.count)
    }

    static func factorTemp(_ sp: Species, _ s: DailySeries, _ day: CivilDate, _ altM: Double) throws -> Double {
        let cfg = sp.weather.tempMean
        let w = try s.window(s.tMean, end: day, days: cfg.windowDays)
        return cfg.c.value(mean(corrected(w, series: s, altM: altM)))
    }

    static func factorRain(_ sp: Species, _ s: DailySeries, _ day: CivilDate) throws -> Double {
        let cfg = sp.weather.rain
        let w = try s.window(s.rain, end: day, days: cfg.windowDays)
        return cfg.mm.value(w.sumInOrder())
    }

    /// Dates de fin de chaque événement : `≥ eventMm` sur `eventDays` jours consécutifs, sans neige.
    static func rainEvents(_ s: DailySeries, _ day: CivilDate, eventMm: Double, eventDays: Int, lookback: Int) throws -> [CivilDate] {
        var out: [CivilDate] = []
        let e = try s.index(of: day)
        let start = Swift.max(0, e - lookback)
        for k in start...e {
            let lo = Swift.max(0, k - eventDays + 1)
            if s.snow[lo...k].contains(where: { $0 > 0 }) { continue }
            if s.rain[lo...k].sumInOrder() >= eventMm { out.append(s.dates[k]) }
        }
        return out
    }

    static func factorTrigger(_ sp: Species, _ s: DailySeries, _ day: CivilDate) throws -> Double {
        let cfg = sp.weather.trigger
        let events = try rainEvents(s, day, eventMm: cfg.eventMm, eventDays: cfg.eventDays, lookback: Int(cfg.lagDays.max))
        var best = 0.0
        for d in events {
            best = Swift.max(best, cfg.lagDays.value(Double(day.days(since: d))))
        }
        return best
    }

    static func factorSoil(_ sp: Species, _ s: DailySeries, _ day: CivilDate) throws -> Double {
        let w = try s.window(s.soilMoisturePct, end: day, days: soilWindowDays)
        return sp.weather.soilMoisturePct.value(mean(Array(w)))
    }

    /// Sévérité d'une nuit, 0–1 (`frost_severity`) : `1 − trapèze(tmin, min = tmin_c,
    /// opt_low = tmin_c + ramp_c, opt_high = +∞, max = +∞)`, soit 1 à `tmin_c` et en dessous, 0 dès
    /// `tmin_c + ramp_c`, linéaire entre. Le trapèze unique du paquet, avec des bornes hautes
    /// infinies : `x <= +∞` est toujours vrai et `max > optHigh` est faux pour +∞ = +∞, donc pas de
    /// rampe descendante — exactement ce que fait `math.inf` dans `trapezoid` côté Python.
    static func frostSeverity(_ tminC: Double, _ cfg: Species.Frost) -> Double {
        let ramp = Trapezoid(min: cfg.tminC, optLow: cfg.tminC + cfg.rampC, optHigh: .infinity, max: .infinity)
        return 1.0 - ramp.value(tminC)
    }

    /// Gel en rampe (spec › Scoring › gel en rampe, 4 nov. 2026), comme `factor_frost` :
    ///
    ///     S = Σ sévérité(tmin corrigée) sur les `window_days` dernières nuits
    ///     facteur = 1 − (1 − factor) × min(1, S / nights)
    ///
    /// `nights` nuits à `tmin_c` ou en dessous donnent × `factor` (l'ancienne marche) ; une seule nuit
    /// à mi-rampe donne `1 − (1 − factor) × 0,5 / nights`. Somme dans l'ordre des nuits, comme Python.
    static func factorFrost(_ sp: Species, _ s: DailySeries, _ day: CivilDate, _ altM: Double) throws -> Double {
        let cfg = sp.weather.frost
        let w = try s.window(s.tMin, end: day, days: cfg.windowDays)
        let vals = corrected(w, series: s, altM: altM)
        let severity = vals.map { frostSeverity($0, cfg) }.sumInOrder()
        return 1.0 - (1.0 - cfg.factor) * Swift.min(1.0, severity / Double(cfg.nights))
    }

    static func factorWaterBalance(_ sp: Species, _ s: DailySeries, _ day: CivilDate) throws -> Double {
        let cfg = sp.weather.waterBalance
        let r = try s.window(s.rain, end: day, days: cfg.windowDays)
        let e = try s.window(s.et0, end: day, days: cfg.windowDays)
        let balance = r.sumInOrder() - e.sumInOrder()
        if balance < cfg.severeMm { return cfg.severeFactor }
        if balance < cfg.moderateMm { return cfg.moderateFactor }
        return 1.0
    }

    static func factorHeat(_ sp: Species, _ s: DailySeries, _ day: CivilDate, _ altM: Double) throws -> Double {
        let cfg = sp.weather.heat
        let w = try s.window(s.tMax, end: day, days: cfg.windowDays)
        let vals = corrected(w, series: s, altM: altM)
        let hot = vals.filter { $0 >= cfg.tmaxC }.count
        return hot >= cfg.days ? cfg.factor : 1.0
    }

    static func factorMemory(_ sp: Species, _ s: DailySeries, _ day: CivilDate) throws -> Double {
        let cfg = sp.weather.memory
        let end = day.adding(days: -sp.weather.rain.windowDays)
        let vals = try s.window(s.rain, end: end, days: cfg.windowDays)
        let tz = cfg.mm.value(vals.sumInOrder())
        return cfg.floor + (1.0 - cfg.floor) * tz
    }

    /// `M` et les facteurs d'un jour, sans persistance (`weather_index_raw`).
    public static func weatherIndexRaw(_ sp: Species, _ s: DailySeries, day: CivilDate, altM: Double) throws -> WeatherFactors {
        let w = sp.weather.weights
        let temp = try factorTemp(sp, s, day, altM)
        let rain = try factorRain(sp, s, day)
        let trigger = try factorTrigger(sp, s, day)
        let soil = try factorSoil(sp, s, day)
        let frost = try factorFrost(sp, s, day, altM)
        let water = try factorWaterBalance(sp, s, day)
        let heat = try factorHeat(sp, s, day, altM)
        let memory = try factorMemory(sp, s, day)
        var f = WeatherFactors(
            temp: temp, rain: rain, trigger: trigger, soilMoisture: soil, frost: frost,
            waterBalance: water, heat: heat, memory: memory, m: 0, mEff: nil
        )
        let base = w.temp * f.temp + w.rain * f.rain + w.trigger * f.trigger + w.soilMoisture * f.soilMoisture
        f.m = base * f.frost * f.waterBalance * f.heat * f.memory
        return f
    }

    /// `M`, `M_eff` (persistance, puis gel et bilan hydrique réappliqués) et détail des facteurs.
    public static func weatherIndex(_ sp: Species, _ s: DailySeries, day: CivilDate, altM: Double) throws -> WeatherFactors {
        var today = try weatherIndexRaw(sp, s, day: day, altM: altM)
        let days = sp.weather.persistence.days
        var mEff = today.m
        if days >= 1 {
            for k in 1...days {
                let pastDay = day.adding(days: -k)
                if !s.contains(pastDay) { break }
                let past = try weatherIndexRaw(sp, s, day: pastDay, altM: altM).m
                mEff = Swift.max(mEff, past * (1.0 - Double(k) / Double(days)))
            }
        }
        mEff = mEff * today.frost * today.waterBalance
        today.mEff = Swift.min(1.0, Swift.max(0.0, mEff))
        return today
    }
}
