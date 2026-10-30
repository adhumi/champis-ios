import Foundation
import Synchronization

/// Lecteur PMTiles v3 : en-tête et répertoire racine lus une fois, répertoires feuilles mis en
/// cache, une requête de données par tuile. `tile(z:x:y:)` renvoie `nil` pour une tuile absente
/// (hors emprise, hors forêt), jamais une tuile vide inventée.
///
/// Classe `Sendable` sans isolation d'acteur : les caches sont derrière un `Mutex`, et les résultats
/// (`Data`, en-tête, entrées) sortent librement vers la carte, qui tourne sur le MainActor.
public final class PMTilesReader: Sendable {
    public let source: any TileSource
    private let maxCachedLeaves: Int

    private struct Cache {
        var header: PMTilesHeader?
        var root: [DirectoryEntry]?
        var leaves: [UInt64: [DirectoryEntry]] = [:]
    }

    private let cache = Mutex(Cache())

    public init(source: any TileSource, maxCachedLeaves: Int = 64) {
        self.source = source
        self.maxCachedLeaves = maxCachedLeaves
    }

    public func readHeader() async throws -> PMTilesHeader {
        if let h = cache.withLock({ $0.header }) { return h }
        let h = try PMTilesHeader(try await source.read(offset: 0, length: PMTilesHeader.size))
        cache.withLock { $0.header = h }
        return h
    }

    public func rootDirectory() async throws -> [DirectoryEntry] {
        if let root = cache.withLock({ $0.root }) { return root }
        let h = try await readHeader()
        let raw = try await source.read(offset: h.rootOffset, length: Int(h.rootLength))
        let entries = try Directory.deserialize(try Inflate.decompress(raw, h.internalCompression))
        cache.withLock { $0.root = entries }
        return entries
    }

    /// Métadonnées JSON du fichier (nom, attribution…), décompressées.
    public func metadata() async throws -> Data {
        let h = try await readHeader()
        guard h.metadataLength > 0 else { return Data() }
        let raw = try await source.read(offset: h.metadataOffset, length: Int(h.metadataLength))
        return try Inflate.decompress(raw, h.internalCompression)
    }

    private func leaf(at offset: UInt64, length: UInt32, header h: PMTilesHeader) async throws -> [DirectoryEntry] {
        if let cached = cache.withLock({ $0.leaves[offset] }) { return cached }
        let raw = try await source.read(offset: h.leafDirectoryOffset + offset, length: Int(length))
        let entries = try Directory.deserialize(try Inflate.decompress(raw, h.internalCompression))
        let limit = maxCachedLeaves
        cache.withLock {
            if $0.leaves.count >= limit { $0.leaves.removeAll(keepingCapacity: true) }
            $0.leaves[offset] = entries
        }
        return entries
    }

    /// Octets de la tuile (décompressés si le fichier compresse ses tuiles), ou `nil` si absente.
    public func tile(z: Int, x: Int, y: Int) async throws -> Data? {
        let h = try await readHeader()
        guard z >= h.minZoom, z <= h.maxZoom else { return nil }
        guard x >= 0, y >= 0, x < (1 << z), y < (1 << z) else { return nil }  // hors niveau : jamais de trap
        let id = TileID.fromZXY(z: z, x: x, y: y)
        var entries = try await rootDirectory()
        for _ in 0...4 {  // la spécification borne la profondeur à quelques niveaux
            guard let e = Directory.find(entries, tileID: id) else { return nil }
            if e.isLeafDirectory {
                entries = try await leaf(at: e.offset, length: e.length, header: h)
                continue
            }
            guard e.length > 0 else { return nil }
            let raw = try await source.read(offset: h.tileDataOffset + e.offset, length: Int(e.length))
            return try Inflate.decompress(raw, h.tileCompression)
        }
        throw PMTilesError.corruptDirectory("répertoires imbriqués trop profonds")
    }
}
