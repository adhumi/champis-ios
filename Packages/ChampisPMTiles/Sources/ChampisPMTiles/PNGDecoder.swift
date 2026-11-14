import Foundation

/// Image décodée : `data` contient `width × height × channels` octets, pixels de gauche à droite
/// et de haut en bas.
public struct DecodedPNG: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let channels: Int
    public let data: [UInt8]

    public init(width: Int, height: Int, channels: Int, data: [UInt8]) {
        self.width = width
        self.height = height
        self.channels = channels
        self.data = data
    }

    /// Valeur du premier canal et alpha (255 sans canal alpha) du pixel (x, y).
    public func valueAndAlpha(x: Int, y: Int) -> (value: UInt8, alpha: UInt8) {
        let i = (y * width + x) * channels
        let alpha: UInt8 = (channels == 2 || channels == 4) ? data[i + channels - 1] : 255
        return (data[i], alpha)
    }
}

/// Décodeur PNG minimal pour les tuiles de données du pipeline : 8 bits, gris (0), RGB (2),
/// gris + alpha (4), RGBA (6), non entrelacé. Port de `web/png.js`.
///
/// Les dimensions sont contrôlées dès l'IHDR, avant toute allocation : `maxSide` au plus, et
/// exactement `side` quand l'appelant le donne (une tuile fait 256 × 256). La décompression est
/// bornée par la taille que ces dimensions imposent, jamais par ce que le flux prétend contenir.
public enum PNGDecoder {
    static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    static let channelsByColorType: [UInt8: Int] = [0: 1, 2: 3, 4: 2, 6: 4]
    /// Côté des tuiles de données, en pixels.
    public static let tileSide = 256
    /// Côté maximal accepté sans `side` : 1024 × 1024 × 4 canaux, soit 4 Mio décodés au plus.
    public static let maxSide = 1024

    /// `side` : côté exigé (largeur et hauteur) ; `nil` accepte toute image jusqu'à `maxSide`.
    public static func decode(_ png: Data, side: Int? = nil) throws -> DecodedPNG {
        let b = [UInt8](png)
        guard b.count >= 8, Array(b[0..<8]) == signature else { throw PNGError.badSignature }
        var pos = 8
        var width = 0, height = 0, channels = 0
        var haveHeader = false
        var idat: [UInt8] = []
        while pos + 8 <= b.count {
            let length = Int(UInt32(b[pos]) << 24 | UInt32(b[pos + 1]) << 16 | UInt32(b[pos + 2]) << 8 | UInt32(b[pos + 3]))
            let type = String(decoding: b[(pos + 4)..<(pos + 8)], as: UTF8.self)
            let start = pos + 8
            guard length <= b.count - start else { throw PNGError.truncatedChunk(type) }
            switch type {
            case "IHDR":
                guard length >= 13 else { throw PNGError.truncatedChunk(type) }
                guard !haveHeader else { throw PNGError.unsupported("deux en-têtes IHDR") }
                width = Int(UInt32(b[start]) << 24 | UInt32(b[start + 1]) << 16 | UInt32(b[start + 2]) << 8 | UInt32(b[start + 3]))
                height = Int(UInt32(b[start + 4]) << 24 | UInt32(b[start + 5]) << 16 | UInt32(b[start + 6]) << 8 | UInt32(b[start + 7]))
                let depth = b[start + 8]
                let colorType = b[start + 9]
                let interlace = b[start + 12]
                guard width >= 1, height >= 1, width <= maxSide, height <= maxSide else {
                    throw PNGError.unsupported("dimensions \(width) × \(height)")
                }
                if let side {
                    guard width == side, height == side else {
                        throw PNGError.unsupported("dimensions \(width) × \(height), \(side) × \(side) attendu")
                    }
                }
                guard depth == 8, let count = channelsByColorType[colorType] else {
                    throw PNGError.unsupported("\(depth) bits, type de couleur \(colorType)")
                }
                guard interlace == 0 else { throw PNGError.unsupported("entrelacement") }
                channels = count
                haveHeader = true
            case "IDAT":
                guard haveHeader else { throw PNGError.missingHeader }
                idat.append(contentsOf: b[start..<(start + length)])
            case "IEND":
                pos = b.count
                continue
            default:
                break
            }
            pos = start + length + 4  // + CRC, non vérifié
        }
        guard haveHeader else { throw PNGError.missingHeader }
        let expected = height * (1 + width * channels)
        let raw = [UInt8](try Inflate.zlib(Data(idat), limit: expected))
        guard raw.count >= expected else { throw PNGError.shortData(expected: expected, got: raw.count) }
        let data = try unfilter(raw, width: width, height: height, bpp: channels)
        return DecodedPNG(width: width, height: height, channels: channels, data: data)
    }

    /// Défiltre les lignes (filtres 0 à 4 de la spécification PNG) ; `bpp` = octets par pixel.
    static func unfilter(_ raw: [UInt8], width: Int, height: Int, bpp: Int) throws -> [UInt8] {
        let stride = width * bpp
        var out = [UInt8](repeating: 0, count: stride * height)
        var src = 0
        for y in 0..<height {
            let type = raw[src]
            src += 1
            let row = y * stride
            let prev = row - stride
            for i in 0..<stride {
                let x = Int(raw[src + i])
                let a = i >= bpp ? Int(out[row + i - bpp]) : 0
                let bUp = y > 0 ? Int(out[prev + i]) : 0
                let c = (y > 0 && i >= bpp) ? Int(out[prev + i - bpp]) : 0
                let v: Int
                switch type {
                case 0: v = x
                case 1: v = x + a
                case 2: v = x + bUp
                case 3: v = x + ((a + bUp) >> 1)
                case 4: v = x + paeth(a, bUp, c)
                default: throw PNGError.badFilter(type, row: y)
                }
                out[row + i] = UInt8(truncatingIfNeeded: v)
            }
            src += stride
        }
        return out
    }

    static func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
        let p = a + b - c
        let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
        if pa <= pb && pa <= pc { return a }
        return pb <= pc ? b : c
    }
}
