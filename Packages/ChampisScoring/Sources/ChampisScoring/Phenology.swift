/// Fenêtre phénologique `Φ` : 0 hors saison, 0,25 dès `season.start`, 1 au pic, rampes
/// linéaires de `ramp_days`, pic secondaire fusionné par max, décalage altitudinal du début et de
/// la fin (règle 8 du modèle). Même arithmétique en jours de l'année que `phenology_window`.
public enum Phenology {
    public static let phiFloor = 0.25

    static func shiftDays(_ shift: Species.AltitudeShift?, altM: Double, perHundred: Double?) -> Int {
        guard let shift else { return 0 }
        let raw = (perHundred ?? 0) * (altM - shift.referenceM) / 100.0
        let mx = abs(shift.maxDays)
        return roundHalfUp(Swift.max(-mx, Swift.min(mx, raw)))
    }

    static func doy(_ md: String, year: Int) throws -> Int {
        let (m, d) = try CivilDate.monthDay(md)
        return CivilDate.dayOfYear(month: m, day: d, year: year)
    }

    /// Ordinal d'un `MM-DD` pour `year` ; un 29 février compte comme le 28 (comme `_date_md`).
    static func ordinal(_ md: (Int, Int), year: Int) -> Int {
        var d = md.1
        if md.0 == 2, d == 29 { d = 28 }
        return CivilDate(year: year, month: md.0, day: d).ordinal
    }

    /// Une saison dont `season.end` précède `season.start` passe le 1er janvier (`season_wraps`,
    /// décision du 9 nov. 2026).
    public static func seasonWraps(_ p: Species.Phenology) throws -> Bool {
        let s = try CivilDate.monthDay(p.season.start)
        let e = try CivilDate.monthDay(p.season.end)
        return e.0 < s.0 || (e.0 == s.0 && e.1 < s.1)
    }

    /// `(d, sStart, sEnd, pStart, pEnd)` sur un même axe entier, décalages compris (`_season_axis`) :
    /// jours de l'année de `day` pour une saison dans l'année civile (inchangé : une fin décalée
    /// au-delà du 31 décembre ne déborde pas), ordinaux de dates pour une saison à cheval sur le
    /// 1er janvier, la saison en cours ayant commencé l'année de `day` ou l'année d'avant.
    static func seasonAxis(_ p: Species.Phenology, day: CivilDate, ds: Int, de: Int) throws -> (Int, Int, Int, Int, Int) {
        let s0 = try CivilDate.monthDay(p.season.start)
        let e0 = try CivilDate.monthDay(p.season.end)
        let ps0 = try CivilDate.monthDay(p.peak.start)
        let pe0 = try CivilDate.monthDay(p.peak.end)
        if try !seasonWraps(p) {
            let year = day.year
            return (
                day.dayOfYear,
                CivilDate.dayOfYear(month: s0.0, day: s0.1, year: year) + ds,
                CivilDate.dayOfYear(month: e0.0, day: e0.1, year: year) + de,
                CivilDate.dayOfYear(month: ps0.0, day: ps0.1, year: year) + ds,
                CivilDate.dayOfYear(month: pe0.0, day: pe0.1, year: year) + de
            )
        }
        func before(_ a: (Int, Int), _ b: (Int, Int)) -> Bool { a.0 < b.0 || (a.0 == b.0 && a.1 < b.1) }
        let d = day.ordinal
        var last = (d, 0, 0, 0, 0)
        for year in [day.year - 1, day.year] {
            let sStart = ordinal(s0, year: year) + ds
            let sEnd = ordinal(e0, year: year + 1) + de
            let pStart = ordinal(ps0, year: year + (before(ps0, s0) ? 1 : 0)) + ds
            let pEnd = ordinal(pe0, year: year + (before(pe0, s0) ? 1 : 0)) + de
            last = (d, sStart, sEnd, pStart, pEnd)
            if sStart <= d && d <= sEnd { return last }
        }
        return last
    }

    public static func window(_ sp: Species, day: CivilDate, altM: Double) throws -> Double {
        let p = sp.phenology
        let year = day.year
        let ds = shiftDays(p.altitudeShift, altM: altM, perHundred: p.altitudeShift?.startDaysPer100m)
        let de = shiftDays(p.altitudeShift, altM: altM, perHundred: p.altitudeShift?.endDaysPer100m)

        let (dayOfYear, sStart, sEnd, pStart, pEnd) = try seasonAxis(p, day: day, ds: ds, de: de)
        let ramp = p.rampDays

        var phi = 0.0
        if sStart <= dayOfYear && dayOfYear <= sEnd {
            phi = phiFloor
            if pStart <= dayOfYear && dayOfYear <= pEnd {
                phi = 1.0
            } else if dayOfYear < pStart {
                let rampStart = Swift.max(sStart, pStart - ramp)
                if dayOfYear >= rampStart && pStart > rampStart {
                    phi = phiFloor + (1.0 - phiFloor) * Double(dayOfYear - rampStart) / Double(pStart - rampStart)
                }
            } else {
                let rampEnd = Swift.min(sEnd, pEnd + ramp)
                if dayOfYear <= rampEnd && rampEnd > pEnd {
                    phi = 1.0 - (1.0 - phiFloor) * Double(dayOfYear - pEnd) / Double(rampEnd - pEnd)
                }
            }
        }
        if let sec = p.secondaryPeak {  // pic secondaire : toujours dans l'année civile de `day`
            let a = try doy(sec.start, year: year) + ds
            let b = try doy(sec.end, year: year) + de
            if a <= day.dayOfYear && day.dayOfYear <= b {
                phi = Swift.max(phi, sec.phi)
            }
        }
        return Swift.min(1.0, Swift.max(0.0, phi))
    }
}
