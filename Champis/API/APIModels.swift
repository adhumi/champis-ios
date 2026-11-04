import ChampisScoring
import Foundation

/// Réponse de `GET /species` : espèces et palette telles quelles (règle 10 du modèle : rien en dur
/// dans l'app). Les blocs `terrain` des espèces ne sont pas décodés, l'app ne calcule pas T.
nonisolated struct SpeciesCatalog: Codable, Sendable {
    let scoringVersion: String
    let speciesHash: String
    let palette: Palette
    let species: [String: Species]

    enum CodingKeys: String, CodingKey {
        case palette, species
        case scoringVersion = "scoring_version"
        case speciesHash = "species_hash"
    }
}

/// Manifeste `GET /tiles` : un PMTiles par espèce (`T-<espèce>-<hash>-p<version>-d<dh>.pmtiles`) et
/// la couche des classes d'altitude (`A-300m-d<dh>.pmtiles`). `url` est absolue (mode presign) ou
/// relative à l'API (mode proxy, `/tiles/<nom>`) : le client suit le manifeste, il ne choisit pas.
nonisolated struct TilesManifest: Codable, Sendable {
    nonisolated struct Entry: Codable, Hashable, Sendable {
        let kind: String
        let name: String
        let url: String
        let bytes: Int?
        let species: String?
        let hash: String?
        let scoringVersion: String?
        let deptsHash: String?
        let classM: Int?
        /// Jeu d'un seul département (hors ligne de l'app), sinon absent.
        let dept: String?

        enum CodingKeys: String, CodingKey {
            case kind, name, url, bytes, species, hash, dept
            case scoringVersion = "scoring_version"
            case deptsHash = "depts_hash"
            case classM = "class_m"
        }
    }

    let configured: Bool
    let mode: String?
    let generated: String?
    let tiles: [Entry]
}

/// Cellule de la grille météo (~5 km) telle que l'API la décrit.
nonisolated struct WeatherCellInfo: Codable, Hashable, Sendable {
    let id: String
    let lat: Double
    let lon: Double
    /// Centres des classes de 300 m calculées pour la cellule (150, 450, …).
    let altClasses: [Double]
    /// Altitude médiane de la forêt de la cellule ; repli quand la couche A ne donne rien.
    let elevationM: Double?

    enum CodingKeys: String, CodingKey {
        case id, lat, lon
        case altClasses = "alt_classes"
        case elevationM = "elevation_m"
    }
}

/// `M`, `M_eff` et `Φ` d'une espèce pour un jour et une classe d'altitude.
nonisolated struct WeatherRow: Codable, Hashable, Sendable {
    let m: Double
    let mEff: Double
    let phi: Double
    /// Détail des facteurs (`GET /weather` seulement) : `temp`, `rain`, `trigger`, `soil_moisture`,
    /// `frost`, `water_balance`, `heat`, `memory`, chacun dans [0, 1].
    let factors: [String: Double]?
    /// Phrases en clair de l'API (`GET /weather` seulement, lot 2) : pluie, sol, freins, saison.
    let summary: [String]?
    /// Âge en jours de la pluie déclenchante retenue ; `nil` sans événement (ou hors détail).
    let triggerDays: Int?

    enum CodingKeys: String, CodingKey {
        case m = "M"
        case mEff = "M_eff"
        case phi, factors, summary
        case triggerDays = "trigger_days"
    }

    /// Facteur appliqué à T : `M_eff × Φ`.
    var factor: Double { mEff * phi }
}

nonisolated struct WeatherDay: Codable, Sendable {
    /// Jour civil ISO (`2026-10-30`).
    let date: String
    /// Clé = centre de classe en mètres, tel que l'API l'écrit (`"150"`, `"450"`).
    let byAlt: [String: WeatherRow]

    enum CodingKeys: String, CodingKey {
        case date
        case byAlt = "by_alt"
    }
}

nonisolated struct CellWeather: Codable, Sendable {
    let cell: WeatherCellInfo
    let stale: Bool
    let species: [String: [WeatherDay]]
}

/// Indice d'un département pour un jour : `value` nil quand la météo manque ; `leading` = espèce qui
/// porte le score d'un groupe (règle 9) ; `coverage` = part de Σ T couverte par la météo.
nonisolated struct DeptDay: Decodable, Hashable, Sendable {
    let date: String
    let value: Double?
    let leading: String?
    let coverage: Double
}

nonisolated struct DeptEntry: Decodable, Sendable {
    let species: [String: [DeptDay]]
    let groups: [String: [DeptDay]]
}

/// Réponse de `GET /departements` : indice `I = Σ T × M_eff × Φ / Σ T` par département, espèce ou
/// groupe et jour, calculé par la pré-chauffe (bandeau des jours ; plus de vue France).
nonisolated struct DepartementsResponse: Decodable, Sendable {
    let today: String
    let computedAt: String
    let scoringVersion: String?
    let departements: [String: DeptEntry]

    enum CodingKeys: String, CodingKey {
        case today, departements
        case computedAt = "computed_at"
        case scoringVersion = "scoring_version"
    }
}

/// Réponse de `GET /weather/bbox` : les 11 jours J−3 → J+7 de chaque cellule de l'emprise.
nonisolated struct WeatherBBoxResponse: Codable, Sendable {
    let today: String
    /// Horodatage ISO 8601 du précalcul servi (la pré-chauffe de l'API) ; `nil` si rien n'a été servi.
    let computedAt: String?
    let scoringVersion: String?
    let cells: [CellWeather]
    /// Cellules sans météo (quota Open-Meteo, historique trop court, pas encore précalculées) :
    /// pixels transparents.
    let unavailable: [String]
    let retryAfter: Int?

    enum CodingKeys: String, CodingKey {
        case today, cells, unavailable
        case computedAt = "computed_at"
        case scoringVersion = "scoring_version"
        case retryAfter = "retry_after"
    }
}

/// Réponse de `GET /weather/field` : le champ météo compact d'un seul jour sur une emprise sans
/// plafond de cellules (la France entière ≈ 20 000 cellules), pour colorer la carte sous le zoom 9
/// (spec › Points ouverts › Carte visible dès l'ouverture, 4 nov. 2026). `f[espèce][classe]` est
/// `M_eff × Φ` pour `day` ; `M_eff` et `Φ` séparés passent par `GET /weather?cell=`.
nonisolated struct WeatherFieldResponse: Codable, Sendable {
    nonisolated struct Cell: Codable, Sendable {
        let id: String
        let lat: Double
        let lon: Double
        let elevationM: Double?
        let altClasses: [Double]
        /// Présent dans le JSON seulement s'il est vrai.
        let stale: Bool
        /// espèce → clé de classe (`"150"`) → `M_eff × Φ`.
        let f: [String: [String: Double]]

        enum CodingKeys: String, CodingKey {
            case id, lat, lon, stale, f
            case elevationM = "elevation_m"
            case altClasses = "alt_classes"
        }

        init(id: String, lat: Double, lon: Double, elevationM: Double?, altClasses: [Double], stale: Bool, f: [String: [String: Double]]) {
            self.id = id
            self.lat = lat
            self.lon = lon
            self.elevationM = elevationM
            self.altClasses = altClasses
            self.stale = stale
            self.f = f
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            lat = try c.decode(Double.self, forKey: .lat)
            lon = try c.decode(Double.self, forKey: .lon)
            elevationM = try c.decodeIfPresent(Double.self, forKey: .elevationM)
            altClasses = try c.decodeIfPresent([Double].self, forKey: .altClasses) ?? []
            stale = try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false
            f = try c.decodeIfPresent([String: [String: Double]].self, forKey: .f) ?? [:]
        }

        /// La même description de cellule que `/weather/bbox`.
        var info: WeatherCellInfo {
            WeatherCellInfo(id: id, lat: lat, lon: lon, altClasses: altClasses, elevationM: elevationM)
        }
    }

    let today: String
    let computedAt: String?
    /// Le jour demandé (ISO), le seul que `f` décrit.
    let day: String
    let scoringVersion: String?
    let cells: [Cell]
    /// Nombre de cellules de l'emprise sans précalcul : leurs pixels restent transparents.
    let unavailable: Int

    enum CodingKeys: String, CodingKey {
        case today, day, cells, unavailable
        case computedAt = "computed_at"
        case scoringVersion = "scoring_version"
    }

    var anyStale: Bool { cells.contains { $0.stale } }
}
