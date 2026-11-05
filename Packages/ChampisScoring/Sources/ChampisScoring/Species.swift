import Foundation

/// Paramètres d'une espèce, tels que `/species` les renvoie (identiques à `species/<id>.json`).
/// Seuls les blocs que le client calcule sont décodés : `phenology` et `weather`.
///
/// Clés JSON explicites, en `snake_case` : la conversion automatique de Foundation met une
/// majuscule au « m » de `end_days_per_100m` et perdait le décalage altitudinal.
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

        enum CodingKeys: String, CodingKey {
            case referenceM = "reference_m"
            case startDaysPer100m = "start_days_per_100m"
            case endDaysPer100m = "end_days_per_100m"
            case maxDays = "max_days"
        }
    }

    public struct Phenology: Codable, Hashable, Sendable {
        public let season: MonthDayRange
        public let peak: MonthDayRange
        public let rampDays: Int
        public let altitudeShift: AltitudeShift?
        public let secondaryPeak: SecondaryPeak?

        enum CodingKeys: String, CodingKey {
            case season, peak
            case rampDays = "ramp_days"
            case altitudeShift = "altitude_shift"
            case secondaryPeak = "secondary_peak"
        }
    }

    public struct TempMean: Codable, Hashable, Sendable {
        public let windowDays: Int
        public let c: Trapezoid

        enum CodingKeys: String, CodingKey {
            case windowDays = "window_days"
            case c
        }
    }

    public struct Rain: Codable, Hashable, Sendable {
        public let windowDays: Int
        public let mm: Trapezoid

        enum CodingKeys: String, CodingKey {
            case windowDays = "window_days"
            case mm
        }
    }

    public struct Trigger: Codable, Hashable, Sendable {
        public let eventMm: Double
        public let eventDays: Int
        public let lagDays: Trapezoid

        enum CodingKeys: String, CodingKey {
            case eventMm = "event_mm"
            case eventDays = "event_days"
            case lagDays = "lag_days"
        }
    }

    /// Gel en rampe (spec › Scoring › gel en rampe, 4 nov. 2026). `ramp_c` est obligatoire dans le
    /// schéma : une espèce sans rampe ne se décode pas, plutôt que de retomber sur une marche.
    public struct Frost: Codable, Hashable, Sendable {
        public let tminC: Double
        /// Largeur de la rampe au-dessus de `tminC`, en °C (> 0).
        public let rampC: Double
        public let nights: Int
        public let windowDays: Int
        public let factor: Double

        enum CodingKeys: String, CodingKey {
            case tminC = "tmin_c"
            case rampC = "ramp_c"
            case nights, factor
            case windowDays = "window_days"
        }
    }

    public struct WaterBalance: Codable, Hashable, Sendable {
        public let windowDays: Int
        public let moderateMm: Double
        public let severeMm: Double
        public let moderateFactor: Double
        public let severeFactor: Double

        enum CodingKeys: String, CodingKey {
            case windowDays = "window_days"
            case moderateMm = "moderate_mm"
            case severeMm = "severe_mm"
            case moderateFactor = "moderate_factor"
            case severeFactor = "severe_factor"
        }
    }

    public struct Heat: Codable, Hashable, Sendable {
        public let tmaxC: Double
        public let days: Int
        public let windowDays: Int
        public let factor: Double

        enum CodingKeys: String, CodingKey {
            case tmaxC = "tmax_c"
            case days, factor
            case windowDays = "window_days"
        }
    }

    public struct Memory: Codable, Hashable, Sendable {
        public let windowDays: Int
        public let mm: Trapezoid
        public let floor: Double

        enum CodingKeys: String, CodingKey {
            case windowDays = "window_days"
            case mm, floor
        }
    }

    public struct Persistence: Codable, Hashable, Sendable {
        public let days: Int
    }

    public struct Weights: Codable, Hashable, Sendable {
        public let temp: Double
        public let rain: Double
        public let trigger: Double
        public let soilMoisture: Double

        enum CodingKeys: String, CodingKey {
            case temp, rain, trigger
            case soilMoisture = "soil_moisture"
        }
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

        enum CodingKeys: String, CodingKey {
            case rain, trigger, frost, heat, memory, persistence, weights
            case tempMean = "temp_mean"
            case soilMoisturePct = "soil_moisture_pct"
            case waterBalance = "water_balance"
        }
    }

    /// Fiche en mots de l'onglet Guide et du site (lot 4) : jamais d'aide à l'identification.
    /// Autoporteuse (`references`) et hors de l'empreinte d'espèce : la relire ne régénère rien.
    public struct About: Codable, Hashable, Sendable {
        public struct Confusion: Codable, Hashable, Sendable {
            public let name: String
            public let latin: String
            /// Ce qu'on risque.
            public let risk: String
            /// Comment la distinguer.
            public let tell: String
            public let refs: [String]
        }

        /// Photo Wikimedia Commons sous licence libre ; le crédit s'affiche sous l'image.
        public struct Photo: Codable, Hashable, Sendable {
            public let url: String
            public let page: String
            public let author: String
            public let license: String
        }

        public let summary: String
        public let habitat: String
        public let season: String
        public let confusions: [Confusion]
        public let photo: Photo?
        public let refs: [String]
        public let references: [String: String]
    }

    public let id: String
    public let names: Names?
    public let group: Group?
    public let phenology: Phenology
    public let weather: Weather
    public let about: About?

    /// Décode un fichier espèce (clés `snake_case` du dépôt, telles quelles).
    public static func decode(_ data: Data) throws -> Species {
        try JSONDecoder().decode(Species.self, from: data)
    }

    /// Longueur minimale de série avant J pour calculer `M_eff` sans troncature.
    public var requiredSeriesDays: Int {
        weather.memory.windowDays + weather.rain.windowDays + weather.persistence.days
    }
}
