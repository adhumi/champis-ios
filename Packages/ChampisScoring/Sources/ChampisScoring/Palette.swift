import Foundation

/// `shared/palette.json` tel que `/species` le renvoie : seuils d'affichage et couleurs, encodage
/// des tuiles. Rien de tout cela n'est écrit en dur dans l'app (règle 10 du modèle).
public struct Palette: Codable, Hashable, Sendable {
    public struct Threshold: Codable, Hashable, Sendable {
        public let min: Double
        public let label: String
        public let fr: String
        public let hex: String
    }

    public struct TileEncoding: Codable, Hashable, Sendable {
        public let channel: String
        public let scale: Double
        public let nodata: Int
    }

    public struct AltEncoding: Codable, Hashable, Sendable {
        public let channel: String
        public let classM: Double
        public let nodata: Int

        enum CodingKeys: String, CodingKey {
            case channel, nodata
            case classM = "class_m"
        }
    }

    /// Encodage des PMTiles par groupe (`G-<groupe>-…`, spec › Points ouverts › PMTiles par groupe,
    /// 4 nov. 2026) : un canal par espèce dans l'ordre de `species` du manifeste, `channels` nomme
    /// l'ordre des octets du pixel (`"rgba"`), canal = `T × scale`, `nodata` = pas de forêt pour ce
    /// canal. L'alpha est un canal de données, jamais une transparence.
    public struct GroupTileEncoding: Codable, Hashable, Sendable {
        public let channels: String
        public let scale: Double
        public let nodata: Int

        public init(channels: String, scale: Double, nodata: Int) {
            self.channels = channels
            self.scale = scale
            self.nodata = nodata
        }
    }

    public let version: Int
    public let thresholds: [Threshold]
    public let nodataHex: String
    public let tileEncoding: TileEncoding
    public let altEncoding: AltEncoding
    /// Absent sur une API antérieure au 5 nov. 2026 : l'app lit alors les `T`, jamais un `G`.
    public let groupTileEncoding: GroupTileEncoding?

    enum CodingKeys: String, CodingKey {
        case version, thresholds
        case nodataHex = "nodata_hex"
        case tileEncoding = "tile_encoding"
        case altEncoding = "alt_encoding"
        case groupTileEncoding = "group_tile_encoding"
    }

    /// Clés `snake_case` explicites : pas de conversion automatique (voir `Species`).
    public static func decode(_ data: Data) throws -> Palette {
        try JSONDecoder().decode(Palette.self, from: data)
    }

    /// Classe d'un score : premier seuil (dans l'ordre du fichier) dont `min ≤ value`, sinon le dernier.
    public func classify(_ value: Double) -> Threshold {
        thresholds.first { value >= $0.min } ?? thresholds[thresholds.count - 1]
    }
}

/// Score d'un groupe (règle 9) : maximum des espèces ; `leading` = celle qui le porte, la première
/// par ordre alphabétique en cas d'égalité.
public struct GroupScore: Hashable, Sendable {
    public let score: Double
    public let leading: String?

    public init(scores: [String: Double]) {
        guard !scores.isEmpty else {
            self.score = 0.0
            self.leading = nil
            return
        }
        let best = scores.sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }[0]
        self.score = best.value
        self.leading = best.key
    }
}
