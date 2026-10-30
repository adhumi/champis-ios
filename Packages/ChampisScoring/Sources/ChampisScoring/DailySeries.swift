/// Séries journalières alignées sur des dates croissantes et contiguës, températures de la
/// cellule **non corrigées** (la correction d'altitude est faite au calcul), humidité du sol déjà
/// en percentile 0–1 de la climatologie de la cellule.
public struct DailySeries: Sendable {
    public let dates: [CivilDate]
    public let tMean: [Double]
    public let tMin: [Double]
    public let tMax: [Double]
    public let rain: [Double]
    public let snow: [Double]
    public let et0: [Double]
    public let soilMoisturePct: [Double]
    public let cellElevationM: Double

    private let firstOrdinal: Int

    public init(
        dates: [CivilDate], tMean: [Double], tMin: [Double], tMax: [Double], rain: [Double],
        snow: [Double], et0: [Double], soilMoisturePct: [Double], cellElevationM: Double
    ) throws {
        for (a, b) in zip(dates, dates.dropFirst()) where b.days(since: a) != 1 {
            throw ScoringError.nonContiguousSeries(a, b)
        }
        let n = dates.count
        for (name, values) in [
            ("t_mean", tMean), ("t_min", tMin), ("t_max", tMax), ("rain", rain),
            ("snow", snow), ("et0", et0), ("soil_moisture_pct", soilMoisturePct),
        ] where values.count != n {
            throw ScoringError.lengthMismatch(name, values.count, n)
        }
        self.dates = dates
        self.tMean = tMean
        self.tMin = tMin
        self.tMax = tMax
        self.rain = rain
        self.snow = snow
        self.et0 = et0
        self.soilMoisturePct = soilMoisturePct
        self.cellElevationM = cellElevationM
        self.firstOrdinal = dates.first?.ordinal ?? 0
    }

    public func contains(_ date: CivilDate) -> Bool {
        let i = date.ordinal - firstOrdinal
        return i >= 0 && i < dates.count
    }

    /// Indice de `date` dans la série, ou erreur si elle est hors série (comme `DailySeries.i`).
    public func index(of date: CivilDate) throws -> Int {
        guard contains(date) else { throw ScoringError.dateOutOfSeries(date) }
        return date.ordinal - firstOrdinal
    }

    /// Les `days` dernières valeurs se terminant à `end` inclus ; erreur si la série est trop courte.
    public func window(_ values: [Double], end: CivilDate, days: Int) throws -> ArraySlice<Double> {
        let e = try index(of: end)
        let s = e - days + 1
        guard s >= 0 else {
            throw ScoringError.seriesTooShort(requested: days, available: e + 1, end: end)
        }
        return values[s...e]
    }
}

extension Sequence where Element == Double {
    /// Somme dans l'ordre, comme `sum()` en Python (l'ordre compte pour les arrondis).
    @inlinable
    func sumInOrder() -> Double {
        var acc = 0.0
        for v in self { acc += v }
        return acc
    }
}
