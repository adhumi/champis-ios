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

/// Manifeste `GET /tiles` : un PMTiles par espèce (`T-<espèce>-<hash>-p<version>-d<dh>.pmtiles`),
/// la couche des classes d'altitude (`A-300m-d<dh>.pmtiles`) et, depuis le 5 nov. 2026, un PMTiles
/// par groupe d'affichage (`G-<groupe>-<hash>-p<version>-d<dh>[-<partie>].pmtiles`, un canal par
/// espèce, spec › Points ouverts › Les clients lisent les PMTiles par groupe). `url` est absolue
/// (mode presign) ou relative à l'API (mode proxy, `/tiles/<nom>`) : le client suit le manifeste,
/// il ne choisit pas.
nonisolated struct TilesManifest: Codable, Sendable {
    nonisolated struct Entry: Codable, Hashable, Sendable {
        let kind: String
        let name: String
        let url: String
        let bytes: Int?
        /// Espèce d'un `T` (clé JSON `species`, une chaîne) ; `nil` pour `A` et `G`.
        let species: String?
        let hash: String?
        let scoringVersion: String?
        let deptsHash: String?
        let classM: Int?
        /// Jeu d'un seul département (hors ligne de l'app), sinon absent.
        let dept: String?
        /// Groupe d'affichage d'un `G` (`group.id` des fichiers d'espèces).
        let group: String?
        /// Espèces d'un `G` dans l'ordre des canaux (même clé JSON `species`, un tableau) ; `nil` sinon.
        let channels: [String]?
        /// Seconde partie d'un groupe de plus de quatre espèces (suffixe `-2`) ; absent sinon.
        let part: Int?

        enum CodingKeys: String, CodingKey {
            case kind, name, url, bytes, species, hash, dept, group, part
            case scoringVersion = "scoring_version"
            case deptsHash = "depts_hash"
            case classM = "class_m"
        }

        var isGroup: Bool { kind == "G" }

        /// Espèces servies par l'entrée : celle du `T`, celles des canaux du `G`.
        var coveredSpecies: [String] {
            channels ?? species.map { [$0] } ?? []
        }
    }

    let configured: Bool
    let mode: String?
    let generated: String?
    let tiles: [Entry]

    enum CodingKeys: String, CodingKey {
        case configured, mode, generated, tiles
    }
}

/// Une entrée invalide est ignorée, pas fatale : `name` et `dept` servent de chemins sur
/// l'appareil (cache des tuiles, départements embarqués) et sont contrôlés ici (`SafePath`,
/// audit du 13 nov. 2026) ; le reste du manifeste se lit quand même. L'init de décodage vit dans
/// une extension pour garder l'init membre à membre (tests).
nonisolated extension TilesManifest {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configured = try c.decode(Bool.self, forKey: .configured)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        generated = try c.decodeIfPresent(String.self, forKey: .generated)
        tiles = try c.decode([LenientTilesEntry].self, forKey: .tiles).compactMap(\.entry)
    }
}

/// Une entrée du manifeste, ou `nil` si elle ne se décode pas.
nonisolated struct LenientTilesEntry: Decodable {
    let entry: TilesManifest.Entry?

    init(from decoder: any Decoder) throws {
        entry = try? TilesManifest.Entry(from: decoder)
    }
}

/// `species` est une chaîne pour un `T`, un tableau pour un `G` : décodé selon le type JSON, réécrit
/// de la même façon (le manifeste est gardé sur disque pour démarrer sans réseau). L'init de
/// décodage vit dans une extension pour garder l'init membre à membre (tests).
nonisolated extension TilesManifest.Entry {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        // `name` et `dept` deviennent des chemins sur l'appareil : contrôlés ici, une fois pour toutes
        let fileName = try c.decode(String.self, forKey: .name)
        guard SafePath.isTileFileName(fileName) else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "nom de fichier refusé")
        }
        name = fileName
        url = try c.decode(String.self, forKey: .url)
        bytes = try c.decodeIfPresent(Int.self, forKey: .bytes)
        hash = try c.decodeIfPresent(String.self, forKey: .hash)
        scoringVersion = try c.decodeIfPresent(String.self, forKey: .scoringVersion)
        deptsHash = try c.decodeIfPresent(String.self, forKey: .deptsHash)
        classM = try c.decodeIfPresent(Int.self, forKey: .classM)
        let code = try c.decodeIfPresent(String.self, forKey: .dept)
        if let code, !SafePath.isDepartment(code) {
            throw DecodingError.dataCorruptedError(forKey: .dept, in: c, debugDescription: "code de département refusé")
        }
        dept = code
        group = try c.decodeIfPresent(String.self, forKey: .group)
        part = try c.decodeIfPresent(Int.self, forKey: .part)
        if let list = try? c.decodeIfPresent([String].self, forKey: .species) {
            species = nil
            channels = list
        } else {
            species = try c.decodeIfPresent(String.self, forKey: .species)
            channels = nil
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(url, forKey: .url)
        try c.encodeIfPresent(bytes, forKey: .bytes)
        try c.encodeIfPresent(hash, forKey: .hash)
        try c.encodeIfPresent(scoringVersion, forKey: .scoringVersion)
        try c.encodeIfPresent(deptsHash, forKey: .deptsHash)
        try c.encodeIfPresent(classM, forKey: .classM)
        try c.encodeIfPresent(dept, forKey: .dept)
        try c.encodeIfPresent(group, forKey: .group)
        try c.encodeIfPresent(part, forKey: .part)
        if let channels {
            try c.encode(channels, forKey: .species)
        } else {
            try c.encodeIfPresent(species, forKey: .species)
        }
    }
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
    /// Les faits de `summary` en une phrase rédigée, sans majuscule initiale ni point final
    /// (`GET /weather` seulement, 17 nov. 2026) ; `nil` d'une API ou d'un cache plus anciens.
    var sentence: String? = nil
    /// Sens de la première proposition de `sentence` (`favorable`, `defavorable`, `neutre`), pour
    /// la liaison avec le terrain (18 nov. 2026) ; `nil` d'une réponse plus ancienne.
    var sentenceTone: String? = nil

    enum CodingKeys: String, CodingKey {
        case m = "M"
        case mEff = "M_eff"
        case phi, factors, summary, sentence
        case triggerDays = "trigger_days"
        case sentenceTone = "sentence_tone"
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
    /// Jour de l'API ; lu pour la fiche d'un coin quand rien d'autre ne l'a encore dit.
    var today: String? = nil
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
