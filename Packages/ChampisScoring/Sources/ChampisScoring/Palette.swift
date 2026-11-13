import Foundation

/// `shared/palette.json` tel que `/species` le renvoie : échelle de couleur des pixels, seuils des
/// mots et couleurs de pastille, encodage des tuiles. Rien de tout cela n'est écrit en dur dans
/// l'app (règle 10 du modèle).
public struct Palette: Codable, Hashable, Sendable {
    /// Seuil d'un mot (excellent, bon…). `hex` est la couleur de pastille de la classe (le violet au
    /// milieu de la classe composé sur blanc), jamais celle d'un pixel : voir `pixelColor`.
    public struct Threshold: Codable, Hashable, Sendable {
        public let min: Double
        public let label: String
        public let fr: String
        public let hex: String
    }

    /// Échelle linéaire (spec › Points ouverts › Échelle linéaire du score, 6 nov. 2026) : un seul
    /// violet `hex` dont l'alpha est le score, `alpha = alphaMin + (alphaMax − alphaMin) × S`.
    public struct Scale: Codable, Hashable, Sendable {
        public let hex: String
        public let alphaMin: Double
        public let alphaMax: Double

        enum CodingKeys: String, CodingKey {
            case hex
            case alphaMin = "alpha_min"
            case alphaMax = "alpha_max"
        }

        public init(hex: String, alphaMin: Double, alphaMax: Double) {
            self.hex = hex
            self.alphaMin = alphaMin
            self.alphaMax = alphaMax
        }

        /// `(r, g, b)` de `hex` (`#RRGGBB`, dièse facultatif) ; `nil` si le hex est invalide.
        public var rgb: (r: UInt8, g: UInt8, b: UInt8)? {
            var digits = Substring(hex)
            if digits.hasPrefix("#") { digits = digits.dropFirst() }
            guard digits.count == 6, let v = UInt32(digits, radix: 16) else { return nil }
            return (UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
        }

        /// Alpha sur 8 bits d'un score : `floor(255 × (alphaMin + (alphaMax − alphaMin) × s) + 0,5)`,
        /// `s` borné à [0, 1], en `Double`. `floor(x + 0,5)` et non `rounded()` : la règle au demi de
        /// l'arrondi diffère entre Python, JavaScript et Swift, celle-ci est la même partout
        /// (skill scoring-parity, vecteurs `palette.json › rgba`).
        public func alpha8(for value: Double) -> UInt8 {
            let s = Swift.min(Swift.max(value, 0.0), 1.0)
            let alpha = alphaMin + (alphaMax - alphaMin) * s
            let scaled = (255.0 * alpha + 0.5).rounded(.down)
            return UInt8(Swift.min(Swift.max(scaled, 0.0), 255.0))
        }
    }

    /// Couleur d'un pixel : le violet de l'échelle et son alpha.
    public struct PixelColor: Hashable, Sendable {
        public let r: UInt8
        public let g: UInt8
        public let b: UInt8
        public let a: UInt8

        public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }
    }

    public struct TileEncoding: Codable, Hashable, Sendable {
        public let channel: String
        public let scale: Double
        public let nodata: Int
    }

    /// Couche E (altitude fine, 13 nov. 2026) : gris = indice de la tranche de `stepM` mètres.
    public struct ElevEncoding: Codable, Hashable, Sendable {
        public let stepM: Double
        public let nodata: Int

        enum CodingKeys: String, CodingKey {
            case nodata
            case stepM = "step_m"
        }
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
    /// Absent sur une API antérieure au 6 nov. 2026 : les pixels prennent alors la couleur de leur
    /// classe (`Threshold.hex`), comme avant l'échelle linéaire.
    public let scale: Scale?
    public let thresholds: [Threshold]
    public let nodataHex: String
    public let tileEncoding: TileEncoding
    public let altEncoding: AltEncoding
    /// Absent sur une API antérieure au 13 nov. 2026 : pas de couche E, la classe de la couche A.
    public let elevEncoding: ElevEncoding?
    /// Absent sur une API antérieure au 5 nov. 2026 : l'app lit alors les `T`, jamais un `G`.
    public let groupTileEncoding: GroupTileEncoding?

    enum CodingKeys: String, CodingKey {
        case version, scale, thresholds
        case nodataHex = "nodata_hex"
        case tileEncoding = "tile_encoding"
        case altEncoding = "alt_encoding"
        case elevEncoding = "elev_encoding"
        case groupTileEncoding = "group_tile_encoding"
    }

    /// Clés `snake_case` explicites : pas de conversion automatique (voir `Species`).
    public static func decode(_ data: Data) throws -> Palette {
        try JSONDecoder().decode(Palette.self, from: data)
    }

    /// Classe d'un score : premier seuil (dans l'ordre du fichier) dont `min ≤ value`, sinon le dernier.
    /// Ne donne que le mot (fiche, coins, notifications, graduations de la légende).
    public func classify(_ value: Double) -> Threshold {
        thresholds.first { value >= $0.min } ?? thresholds[thresholds.count - 1]
    }

    /// Couleur d'un pixel de score `value` (échelle linéaire) ; `nil` sans `scale` (API ancienne) ou si
    /// son `hex` est invalide. Validée contre `shared/vectors/palette.json › rgba`.
    public func pixelColor(_ value: Double) -> PixelColor? {
        guard let scale, let rgb = scale.rgb else { return nil }
        return PixelColor(r: rgb.r, g: rgb.g, b: rgb.b, a: scale.alpha8(for: value))
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
