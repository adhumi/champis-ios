import Foundation

/// Paramètres d'une espèce, tels que `/species` les renvoie (identiques à `species/<id>.json`).
/// Seuls les blocs que le client calcule sont décodés : `phenology` et `weather`.
public struct Species: Codable, Hashable, Sendable {
    public struct Group: Codable, Hashable, Sendable {
        public let id: String
        public let fr: String
    }

    public struct Names: Codable, Hashable, Sendable {
        public let fr: String
        public let la: String
    }

    public struct MonthDayRange: Codable, Hashable, Sendable {
        public let start: String  // MM-DD
        public let end: String
    }

    public struct SecondaryPeak: Codable, Hashable, Sendable {
        public let start: String
        public let end: String
        public let phi: Double
    }

    public struct AltitudeShift: Codable, Hashable, Sendable {
        public let referenceM: Double
        public let startDaysPer100m: Double?
        public let endDaysPer100m: Double?
        public let maxDays: Double
    }

    public struct Phenology: Codable, Hashable, Sendable {
        public let season: MonthDayRange
        public let peak: MonthDayRange
        public let rampDays: Int
        public let altitudeShift: AltitudeShift?
        public let secondaryPeak: SecondaryPeak?
    }

    public struct TempMean: Codable, Hashable, Sendable {
        public let windowDays: Int
        public let c: Trapezoid
    }

    public struct Rain: Codable, Hashable, Sendable {
        public let windowDays: Int
        public let mm: Trapezoid
    }

    public struct Trigger: Codable, Hashable, Sendable {
        public let eventMm: Double
        public let eventDays: Int
        public let lagDays: Trapezoid
    }

    public struct Frost: Codable, Hashable, Sendable {
        public let tminC: Double
        public let nights: Int
        public let windowDays: Int
        public let factor: Double
    }

    public struct WaterBalance: Codable, Hashable, Sendable {
        public let windowDays: Int
        public let moderateMm: Double
        public let severeMm: Double
        public let moderateFactor: Double
        public let severeFactor: Double
    }

    public struct Heat: Codable, Hashable, Sendable {
        public let tmaxC: Double
        public let days: Int
        public let windowDays: Int
        public let factor: Double
    }

    public struct Memory: Codable, Hashable, Sendable {
        public let windowDays: Int
        public let mm: Trapezoid
        public let floor: Double
    }

    public struct Persistence: Codable, Hashable, Sendable {
        public let days: Int
    }

    public struct Weights: Codable, Hashable, Sendable {
        public let temp: Double
        public let rain: Double
        public let trigger: Double
        public let soilMoisture: Double
    }

    public struct Weather: Codable, Hashable, Sendable {
        public let tempMean: TempMean
        public let rain: Rain
        public let trigger: Trigger
        public let soilMoisturePct: Trapezoid
        public let frost: Frost
        public let waterBalance: WaterBalance
        public let heat: Heat
        public let memory: Memory
        public let persistence: Persistence
        public let weights: Weights
    }

    public let id: String
    public let names: Names?
    public let group: Group?
    public let phenology: Phenology
    public let weather: Weather

    /// Décode un fichier espèce (clés `snake_case` du dépôt).
    public static func decode(_ data: Data) throws -> Species {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Species.self, from: data)
    }

    /// Longueur minimale de série avant J pour calculer `M_eff` sans troncature.
    public var requiredSeriesDays: Int {
        weather.memory.windowDays + weather.rain.windowDays + weather.persistence.days
    }
}
