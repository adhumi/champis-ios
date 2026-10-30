import Foundation

/// Décompression des répertoires (gzip) et des flux zlib des PNG, par le DEFLATE brut de Foundation.
enum Inflate {
    /// `gzip` (RFC 1952) : en-tête de 10 octets plus champs optionnels, DEFLATE, puis CRC32 et taille.
    static func gunzip(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        guard b.count >= 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else {
            throw PMTilesError.corruptDirectory("gzip : en-tête invalide")
        }
        let flags = b[3]
        var pos = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard pos + 2 <= b.count else { throw PMTilesError.truncated("gzip FEXTRA") }
            let xlen = Int(b[pos]) | Int(b[pos + 1]) << 8
            pos += 2 + xlen
        }
        if flags & 0x08 != 0 { pos = try skipZeroTerminated(b, from: pos) }  // FNAME
        if flags & 0x10 != 0 { pos = try skipZeroTerminated(b, from: pos) }  // FCOMMENT
        if flags & 0x02 != 0 { pos += 2 }  // FHCRC
        guard pos <= b.count - 8 else { throw PMTilesError.truncated("gzip") }
        return try rawDeflate(Data(b[pos..<(b.count - 8)]))
    }

    /// Flux zlib (RFC 1950) des PNG : 2 octets d'en-tête, DEFLATE, 4 octets d'Adler-32.
    static func zlib(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        guard b.count >= 6, b[0] & 0x0F == 8 else { throw PNGError.unsupported("zlib : en-tête invalide") }
        guard b[1] & 0x20 == 0 else { throw PNGError.unsupported("zlib : dictionnaire prédéfini") }
        return try rawDeflate(Data(b[2..<(b.count - 4)]))
    }

    static func rawDeflate(_ data: Data) throws -> Data {
        // `.zlib` de Foundation est le DEFLATE brut, sans en-tête ni somme de contrôle.
        try (data as NSData).decompressed(using: .zlib) as Data
    }

    private static func skipZeroTerminated(_ b: [UInt8], from: Int) throws -> Int {
        var i = from
        while i < b.count, b[i] != 0 { i += 1 }
        guard i < b.count else { throw PMTilesError.truncated("gzip chaîne") }
        return i + 1
    }

    static func decompress(_ data: Data, _ compression: PMCompression) throws -> Data {
        switch compression {
        case .none, .unknown: data
        case .gzip: try gunzip(data)
        case .brotli, .zstd: throw PMTilesError.unsupportedCompression(compression.rawValue)
        }
    }
}
