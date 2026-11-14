import Foundation

/// Une entrée de répertoire : une tuile (`runLength ≥ 1`, répétée sur `runLength` identifiants
/// consécutifs) ou un répertoire feuille (`runLength == 0`), désignée par une plage d'octets.
public struct DirectoryEntry: Sendable, Equatable {
    public let tileID: UInt64
    public let offset: UInt64
    public let length: UInt32
    public let runLength: UInt32

    public init(tileID: UInt64, offset: UInt64, length: UInt32, runLength: UInt32) {
        self.tileID = tileID
        self.offset = offset
        self.length = length
        self.runLength = runLength
    }

    public var isLeafDirectory: Bool { runLength == 0 }
}

public enum Directory {
    /// Décode un répertoire (déjà décompressé) : nombre d'entrées, puis identifiants en deltas,
    /// longueurs de série, longueurs, décalages (0 = contigu à l'entrée précédente, sinon valeur + 1).
    ///
    /// Rien n'est alloué d'après le seul nombre annoncé : une entrée occupe au moins quatre octets
    /// (un par entier variable), le tampon borne donc le nombre d'entrées. Un identifiant, une
    /// longueur ou un décalage qui déborde lève `corruptDirectory`.
    public static func deserialize(_ data: Data) throws -> [DirectoryEntry] {
        var r = ByteReader([UInt8](data))
        let announced = try r.readVarint()
        guard let n = Int(exactly: announced), n <= r.remaining / 4 else {
            throw PMTilesError.corruptDirectory("\(announced) entrées annoncées pour \(r.remaining) octets")
        }
        var ids = [UInt64](repeating: 0, count: n)
        var last: UInt64 = 0
        for i in 0..<n {
            let (next, overflow) = last.addingReportingOverflow(try r.readVarint())
            guard !overflow else { throw PMTilesError.corruptDirectory("identifiant de tuile hors de 64 bits") }
            last = next
            ids[i] = last
        }
        var runs = [UInt32](repeating: 0, count: n)
        for i in 0..<n {
            guard let run = UInt32(exactly: try r.readVarint()) else {
                throw PMTilesError.corruptDirectory("longueur de série hors de 32 bits")
            }
            runs[i] = run
        }
        var lengths = [UInt32](repeating: 0, count: n)
        for i in 0..<n {
            guard let length = UInt32(exactly: try r.readVarint()) else {
                throw PMTilesError.corruptDirectory("longueur hors de 32 bits")
            }
            lengths[i] = length
        }
        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(n)
        for i in 0..<n {
            let tmp = try r.readVarint()
            let offset: UInt64
            if i > 0, tmp == 0 {
                let (next, overflow) = entries[i - 1].offset.addingReportingOverflow(UInt64(entries[i - 1].length))
                guard !overflow else { throw PMTilesError.corruptDirectory("décalage hors de 64 bits") }
                offset = next
            } else {
                guard tmp >= 1 else { throw PMTilesError.corruptDirectory("décalage 0 en tête") }
                offset = tmp - 1
            }
            entries.append(DirectoryEntry(tileID: ids[i], offset: offset, length: lengths[i], runLength: runs[i]))
        }
        return entries
    }

    /// Recherche binaire de `tileID` : l'entrée exacte, sinon la dernière entrée qui le précède si
    /// elle est un répertoire feuille ou si sa série le couvre (`find_tile` de la spécification).
    public static func find(_ entries: [DirectoryEntry], tileID: UInt64) -> DirectoryEntry? {
        var m = 0
        var n = entries.count - 1
        while m <= n {
            let k = (n + m) >> 1
            if tileID > entries[k].tileID {
                m = k + 1
            } else if tileID < entries[k].tileID {
                n = k - 1
            } else {
                return entries[k]
            }
        }
        if n >= 0 {
            if entries[n].runLength == 0 { return entries[n] }
            // `>=` : des entrées non triées (répertoire construit à la main) ne font pas déborder
            if tileID >= entries[n].tileID, tileID - entries[n].tileID < UInt64(entries[n].runLength) { return entries[n] }
        }
        return nil
    }

    /// Encode un répertoire (tests et outils) : inverse exact de `deserialize`.
    public static func serialize(_ entries: [DirectoryEntry]) -> Data {
        var out: [UInt8] = Varint.encode(UInt64(entries.count))
        var last: UInt64 = 0
        for e in entries {
            out += Varint.encode(e.tileID - last)
            last = e.tileID
        }
        for e in entries { out += Varint.encode(UInt64(e.runLength)) }
        for e in entries { out += Varint.encode(UInt64(e.length)) }
        for (i, e) in entries.enumerated() {
            if i > 0, e.offset == entries[i - 1].offset + UInt64(entries[i - 1].length) {
                out += Varint.encode(0)
            } else {
                out += Varint.encode(e.offset + 1)
            }
        }
        return Data(out)
    }
}
