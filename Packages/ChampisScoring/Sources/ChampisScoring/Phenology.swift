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

    public static func window(_ sp: Species, day: CivilDate, altM: Double) throws -> Double {
        let p = sp.phenology
        let year = day.year
        let dayOfYear = day.dayOfYear
        let ds = shiftDays(p.altitudeShift, altM: altM, perHundred: p.altitudeShift?.startDaysPer100m)
        let de = shiftDays(p.altitudeShift, altM: altM, perHundred: p.altitudeShift?.endDaysPer100m)

        let sStart = try doy(p.season.start, year: year) + ds
        let sEnd = try doy(p.season.end, year: year) + de
        let pStart = try doy(p.peak.start, year: year) + ds
        let pEnd = try doy(p.peak.end, year: year) + de
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
        if let sec = p.secondaryPeak {
            let a = try doy(sec.start, year: year) + ds
            let b = try doy(sec.end, year: year) + de
            if a <= dayOfYear && dayOfYear <= b {
                phi = Swift.max(phi, sec.phi)
            }
        }
        return Swift.min(1.0, Swift.max(0.0, phi))
    }
}
