import Foundation
import Synchronization

/// Lecteur PMTiles v3 : en-tête et répertoire racine lus une fois, répertoires feuilles mis en
/// cache, une requête de données par tuile. `tile(z:x:y:)` renvoie `nil` pour une tuile absente
/// (hors emprise, hors forêt), jamais une tuile vide inventée. Les longueurs et décalages lus dans
/// le fichier sont vérifiés avant chaque lecture : répertoire ou métadonnées de plus de
/// `maxDirectoryBytes`, tuile de plus de `maxTileBytes` (ou `maxTileDecompressedBytes` une fois
/// décompressée) lèvent `tooLarge`, un décalage qui déborde `corruptDirectory`.
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
        /// Répertoires feuilles en cours de lecture : les tuiles voisines demandées en même temps
        /// (premier affichage) partagent une seule requête au lieu d'en lancer une chacune.
        var pendingLeaves: [UInt64: Task<[DirectoryEntry], any Error>] = [:]
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
        let length = try PMTilesReader.length(h.rootLength, limit: ChampisPMTiles.maxDirectoryBytes, "répertoire racine")
        let raw = try await source.read(offset: h.rootOffset, length: length)
        let entries = try Directory.deserialize(
            try Inflate.decompress(raw, h.internalCompression, limit: ChampisPMTiles.maxDirectoryBytes)
        )
        cache.withLock { $0.root = entries }
        return entries
    }

    /// Métadonnées JSON du fichier (nom, attribution…), décompressées.
    public func metadata() async throws -> Data {
        let h = try await readHeader()
        guard h.metadataLength > 0 else { return Data() }
        let length = try PMTilesReader.length(h.metadataLength, limit: ChampisPMTiles.maxDirectoryBytes, "métadonnées")
        let raw = try await source.read(offset: h.metadataOffset, length: length)
        return try Inflate.decompress(raw, h.internalCompression, limit: ChampisPMTiles.maxDirectoryBytes)
    }

    /// Longueur lue dans le fichier, convertie sans débordement : nulle ou au-delà de `limit`, le
    /// fichier est refusé avant toute lecture.
    private static func length(_ value: UInt64, limit: Int, _ what: String) throws -> Int {
        guard let length = Int(exactly: value), length <= limit else {
            throw PMTilesError.tooLarge("\(what) : \(value) octets pour \(limit) au plus")
        }
        guard length > 0 else { throw PMTilesError.corruptDirectory("\(what) : longueur nulle") }
        return length
    }

    /// Position absolue d'une plage relative à une section du fichier, sans débordement.
    private static func position(_ base: UInt64, _ offset: UInt64, _ what: String) throws -> UInt64 {
        let (position, overflow) = base.addingReportingOverflow(offset)
        guard !overflow else { throw PMTilesError.corruptDirectory("\(what) : décalage hors de 64 bits") }
        return position
    }

    private func leaf(at offset: UInt64, length: UInt32, header h: PMTilesHeader) async throws -> [DirectoryEntry] {
        if let cached = cache.withLock({ $0.leaves[offset] }) { return cached }
        let source = source
        let task: Task<[DirectoryEntry], any Error> = cache.withLock { c in
            if let running = c.pendingLeaves[offset] { return running }
            let started = Task {
                let count = try PMTilesReader.length(UInt64(length), limit: ChampisPMTiles.maxDirectoryBytes, "répertoire feuille")
                let start = try PMTilesReader.position(h.leafDirectoryOffset, offset, "répertoire feuille")
                let raw = try await source.read(offset: start, length: count)
                return try Directory.deserialize(
                    try Inflate.decompress(raw, h.internalCompression, limit: ChampisPMTiles.maxDirectoryBytes)
                )
            }
            c.pendingLeaves[offset] = started
            return started
        }
        do {
            let entries = try await task.value
            let limit = maxCachedLeaves
            cache.withLock {
                $0.pendingLeaves[offset] = nil
                if $0.leaves[offset] == nil {
                    if $0.leaves.count >= limit { $0.leaves.removeAll(keepingCapacity: true) }
                    $0.leaves[offset] = entries
                }
            }
            return entries
        } catch {
            cache.withLock { $0.pendingLeaves[offset] = nil }
            throw error
        }
    }

    /// Octets de la tuile (décompressés si le fichier compresse ses tuiles), ou `nil` si absente.
    public func tile(z: Int, x: Int, y: Int) async throws -> Data? {
        let h = try await readHeader()
        // l'en-tête peut annoncer un zoom jusqu'à 255 : au-delà de 31, l'identifiant déborderait
        guard z >= 0, z <= ChampisPMTiles.maxZoom, z >= h.minZoom, z <= h.maxZoom else { return nil }
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
            let length = try PMTilesReader.length(UInt64(e.length), limit: ChampisPMTiles.maxTileBytes, "tuile \(z)/\(x)/\(y)")
            let start = try PMTilesReader.position(h.tileDataOffset, e.offset, "tuile \(z)/\(x)/\(y)")
            let raw = try await source.read(offset: start, length: length)
            return try Inflate.decompress(raw, h.tileCompression, limit: ChampisPMTiles.maxTileDecompressedBytes)
        }
        throw PMTilesError.corruptDirectory("répertoires imbriqués trop profonds")
    }
}
