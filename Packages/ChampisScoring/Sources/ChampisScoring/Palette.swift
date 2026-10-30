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

    public let version: Int
    public let thresholds: [Threshold]
    public let nodataHex: String
    public let tileEncoding: TileEncoding
    public let altEncoding: AltEncoding

    enum CodingKeys: String, CodingKey {
        case version, thresholds
        case nodataHex = "nodata_hex"
        case tileEncoding = "tile_encoding"
        case altEncoding = "alt_encoding"
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
