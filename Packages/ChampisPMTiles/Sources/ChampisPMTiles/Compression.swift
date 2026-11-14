import Compression
import Foundation

/// Décompression des répertoires (gzip) et des flux zlib des PNG, par le DEFLATE brut du système.
/// La sortie est toujours bornée par l'appelant : la taille décompressée n'est jamais dictée par le
/// fichier (un flux de quelques octets peut en annoncer des gigaoctets).
enum Inflate {
    enum Failure: Error {
        /// Flux invalide ou interrompu avant sa fin.
        case corrupt
        /// La sortie dépasse la limite donnée.
        case tooLarge
    }

    /// `gzip` (RFC 1952) : en-tête de 10 octets plus champs optionnels, DEFLATE, puis CRC32 et taille.
    static func gunzip(_ data: Data, limit: Int) throws -> Data {
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
        do {
            return try rawDeflate(Data(b[pos..<(b.count - 8)]), limit: limit)
        } catch Failure.tooLarge {
            throw PMTilesError.tooLarge("gzip : plus de \(limit) octets décompressés")
        } catch {
            throw PMTilesError.corruptData("gzip : flux DEFLATE invalide")
        }
    }

    /// Flux zlib (RFC 1950) des PNG : 2 octets d'en-tête, DEFLATE, 4 octets d'Adler-32.
    static func zlib(_ data: Data, limit: Int) throws -> Data {
        let b = [UInt8](data)
        guard b.count >= 6, b[0] & 0x0F == 8 else { throw PNGError.unsupported("zlib : en-tête invalide") }
        guard b[1] & 0x20 == 0 else { throw PNGError.unsupported("zlib : dictionnaire prédéfini") }
        do {
            return try rawDeflate(Data(b[2..<(b.count - 4)]), limit: limit)
        } catch Failure.tooLarge {
            throw PNGError.corrupt("données plus longues que l'image annoncée")
        } catch {
            throw PNGError.corrupt("zlib : flux DEFLATE invalide")
        }
    }

    /// DEFLATE brut (`COMPRESSION_ZLIB` : sans en-tête ni somme de contrôle), décodé par morceaux
    /// dans un tampon fixe ; au-delà de `limit` octets produits, `Failure.tooLarge`, sans avoir
    /// alloué davantage.
    static func rawDeflate(_ data: Data, limit: Int) throws -> Data {
        guard limit >= 0 else { throw Failure.tooLarge }
        guard !data.isEmpty else { throw Failure.corrupt }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Failure.corrupt
        }
        defer { compression_stream_destroy(stream) }
        let chunk = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> Data in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw Failure.corrupt }
            var output = Data()
            stream.pointee.src_ptr = base
            stream.pointee.src_size = raw.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                if produced > 0 {
                    guard produced <= limit - output.count else { throw Failure.tooLarge }
                    output.append(buffer, count: produced)
                }
                if status == COMPRESSION_STATUS_END {
                    return output
                }
                // ni fin de flux ni progrès : flux interrompu, on ne boucle pas
                guard status == COMPRESSION_STATUS_OK, produced > 0 else { throw Failure.corrupt }
            }
        }
    }

    private static func skipZeroTerminated(_ b: [UInt8], from: Int) throws -> Int {
        var i = from
        while i < b.count, b[i] != 0 { i += 1 }
        guard i < b.count else { throw PMTilesError.truncated("gzip chaîne") }
        return i + 1
    }

    /// `limit` : taille maximale de la sortie, vérifiée aussi sans compression.
    static func decompress(_ data: Data, _ compression: PMCompression, limit: Int) throws -> Data {
        switch compression {
        case .none, .unknown:
            guard data.count <= limit else { throw PMTilesError.tooLarge("\(data.count) octets pour \(limit) au plus") }
            return data
        case .gzip:
            return try gunzip(data, limit: limit)
        case .brotli, .zstd:
            throw PMTilesError.unsupportedCompression(compression.rawValue)
        }
    }
}
