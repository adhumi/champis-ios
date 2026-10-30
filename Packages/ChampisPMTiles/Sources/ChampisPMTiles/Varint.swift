/// Lecture séquentielle d'entiers variables (LEB128 non signé, comme protobuf) sur un tableau d'octets.
struct ByteReader {
    let bytes: [UInt8]
    var position: Int = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remaining: Int { bytes.count - position }

    mutating func readVarint() throws -> UInt64 {
        var shift: UInt64 = 0
        var result: UInt64 = 0
        while true {
            guard position < bytes.count else { throw PMTilesError.truncated("varint") }
            let b = bytes[position]
            position += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            guard shift < 64 else { throw PMTilesError.corruptDirectory("varint trop long") }
        }
    }

    mutating func readUInt8() throws -> UInt8 {
        guard position < bytes.count else { throw PMTilesError.truncated("uint8") }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func readUInt32LE() throws -> UInt32 {
        guard position + 4 <= bytes.count else { throw PMTilesError.truncated("uint32") }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[position + i]) << (8 * UInt32(i)) }
        position += 4
        return v
    }

    mutating func readUInt64LE() throws -> UInt64 {
        guard position + 8 <= bytes.count else { throw PMTilesError.truncated("uint64") }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[position + i]) << (8 * UInt64(i)) }
        position += 8
        return v
    }

    mutating func readInt32LE() throws -> Int32 {
        Int32(bitPattern: try readUInt32LE())
    }

    mutating func skip(_ n: Int) throws {
        guard position + n <= bytes.count else { throw PMTilesError.truncated("skip") }
        position += n
    }
}

/// Écriture, pour construire des répertoires dans les tests.
public enum Varint {
    public static func encode(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }
}
