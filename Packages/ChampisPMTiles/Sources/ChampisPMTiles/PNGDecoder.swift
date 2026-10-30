import Foundation

/// Image décodée : `data` contient `width × height × channels` octets, pixels de gauche à droite
/// et de haut en bas.
public struct DecodedPNG: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let channels: Int
    public let data: [UInt8]

    /// Valeur du premier canal et alpha (255 sans canal alpha) du pixel (x, y).
    public func valueAndAlpha(x: Int, y: Int) -> (value: UInt8, alpha: UInt8) {
        let i = (y * width + x) * channels
        let alpha: UInt8 = (channels == 2 || channels == 4) ? data[i + channels - 1] : 255
        return (data[i], alpha)
    }
}

/// Décodeur PNG minimal pour les tuiles de données du pipeline : 8 bits, gris (0), RGB (2),
/// gris + alpha (4), RGBA (6), non entrelacé. Port de `web/png.js`.
public enum PNGDecoder {
    static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    static let channelsByColorType: [UInt8: Int] = [0: 1, 2: 3, 4: 2, 6: 4]

    public static func decode(_ png: Data) throws -> DecodedPNG {
        let b = [UInt8](png)
        guard b.count >= 8, Array(b[0..<8]) == signature else { throw PNGError.badSignature }
        var pos = 8
        var width = 0, height = 0, depth: UInt8 = 0, colorType: UInt8 = 0, interlace: UInt8 = 0
        var haveHeader = false
        var idat: [UInt8] = []
        while pos + 8 <= b.count {
            let length = Int(UInt32(b[pos]) << 24 | UInt32(b[pos + 1]) << 16 | UInt32(b[pos + 2]) << 8 | UInt32(b[pos + 3]))
            let type = String(decoding: b[(pos + 4)..<(pos + 8)], as: UTF8.self)
            let start = pos + 8
            guard start + length <= b.count else { throw PNGError.truncatedChunk(type) }
            switch type {
            case "IHDR":
                guard length >= 13 else { throw PNGError.truncatedChunk(type) }
                width = Int(UInt32(b[start]) << 24 | UInt32(b[start + 1]) << 16 | UInt32(b[start + 2]) << 8 | UInt32(b[start + 3]))
                height = Int(UInt32(b[start + 4]) << 24 | UInt32(b[start + 5]) << 16 | UInt32(b[start + 6]) << 8 | UInt32(b[start + 7]))
                depth = b[start + 8]
                colorType = b[start + 9]
                interlace = b[start + 12]
                haveHeader = true
            case "IDAT":
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
        guard depth == 8, let channels = channelsByColorType[colorType] else {
            throw PNGError.unsupported("\(depth) bits, type de couleur \(colorType)")
        }
        guard interlace == 0 else { throw PNGError.unsupported("entrelacement") }
        let raw = [UInt8](try Inflate.zlib(Data(idat)))
        let expected = height * (1 + width * channels)
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
