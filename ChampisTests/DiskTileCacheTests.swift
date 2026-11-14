import ChampisPMTiles
import Foundation
import Testing
@testable import Champis

struct DiskTileCacheTests {
    static func temporaryCache() throws -> DiskTileCache {
        let root = FileManager.default.temporaryDirectory.appending(path: "champis-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return DiskTileCache(root: root)
    }

    @Test("Écriture, lecture, absence mémorisée, taille, purge et vidage")
    func roundTrip() throws {
        let cache = try Self.temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.root) }
        let file = "T-boletus_edulis-af34c16e-p1.0.0-da1b2c3.pmtiles"
        #expect(cache.read(file: file, z: 12, x: 2078, y: 1409) == .miss)

        try cache.write(file: file, z: 12, x: 2078, y: 1409, data: Data([1, 2, 3, 4]))
        #expect(cache.read(file: file, z: 12, x: 2078, y: 1409) == .tile(Data([1, 2, 3, 4])))
        try cache.write(file: file, z: 12, x: 2079, y: 1409, data: nil)
        #expect(cache.read(file: file, z: 12, x: 2079, y: 1409) == .absent)
        #expect(cache.read(file: "autre.pmtiles", z: 12, x: 2078, y: 1409) == .miss)
        #expect(cache.totalSize() == 4)
        #expect(cache.files() == [file])

        try cache.write(file: "A-300m-d000000.pmtiles", z: 10, x: 1, y: 1, data: Data([9]))
        #expect(cache.files() == ["A-300m-d000000.pmtiles", file])
        let removed = try cache.prune(keeping: [file])
        #expect(removed == ["A-300m-d000000.pmtiles"])
        #expect(cache.files() == [file])
        #expect(cache.read(file: "A-300m-d000000.pmtiles", z: 10, x: 1, y: 1) == .miss)

        try cache.removeAll()
        #expect(cache.files().isEmpty)
        #expect(cache.totalSize() == 0)
        #expect(cache.read(file: file, z: 12, x: 2078, y: 1409) == .miss)
    }

    @Test("Tampon de version : un dossier d'une autre version du fichier est effacé, jamais complété")
    func stamps() throws {
        let cache = try Self.temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.root) }
        let file = "A-300m-da1b2c3.pmtiles"
        let first = DiskTileCache.Stamp(bytes: 4567, etag: "\"v1\"")
        #expect(cache.stamp(file: file) == nil)

        try cache.write(file: file, z: 12, x: 1, y: 1, data: Data([1]), stamp: first)
        try cache.write(file: file, z: 12, x: 2, y: 1, data: nil, stamp: first)
        #expect(cache.stamp(file: file) == first)
        #expect(cache.read(file: file, z: 12, x: 1, y: 1) == .tile(Data([1])))
        #expect(cache.read(file: file, z: 12, x: 2, y: 1) == .absent)

        // même taille, ETag pas encore connu : même version, le tampon garde ce qu'il sait
        try cache.write(file: file, z: 12, x: 3, y: 1, data: Data([3]), stamp: DiskTileCache.Stamp(bytes: 4567, etag: nil))
        #expect(cache.stamp(file: file) == first)
        #expect(cache.read(file: file, z: 12, x: 1, y: 1) == .tile(Data([1])))
        #expect(cache.validate(file: file, against: DiskTileCache.Stamp(bytes: 4567, etag: nil)) == first)

        // même taille, autre ETag : le fichier a été republié, les anciennes tuiles partent
        let second = DiskTileCache.Stamp(bytes: 4567, etag: "\"v2\"")
        try cache.write(file: file, z: 12, x: 4, y: 1, data: Data([4]), stamp: second)
        #expect(cache.stamp(file: file) == second)
        #expect(cache.read(file: file, z: 12, x: 1, y: 1) == .miss)
        #expect(cache.read(file: file, z: 12, x: 2, y: 1) == .miss)
        #expect(cache.read(file: file, z: 12, x: 4, y: 1) == .tile(Data([4])))

        // le manifeste annonce une autre taille : dossier effacé
        #expect(cache.validate(file: file, against: DiskTileCache.Stamp(bytes: 9999, etag: nil)) == nil)
        #expect(cache.read(file: file, z: 12, x: 4, y: 1) == .miss)
        #expect(cache.files().isEmpty)

        // dossier d'avant les tampons : on ne sait pas de quelle version il vient, effacé aussi
        try cache.write(file: file, z: 12, x: 5, y: 1, data: Data([5]))
        #expect(cache.stamp(file: file) == nil)
        #expect(cache.validate(file: file, against: DiskTileCache.Stamp(bytes: 4567, etag: nil)) == nil)
        #expect(cache.read(file: file, z: 12, x: 5, y: 1) == .miss)
        // rien à valider : rien ne se passe
        #expect(cache.validate(file: "absent.pmtiles", against: first) == nil)

        // tampons : une taille ou un ETag connus des deux côtés et différents, c'est une autre version
        #expect(first.matches(DiskTileCache.Stamp(bytes: nil, etag: nil)))
        #expect(first.matches(DiskTileCache.Stamp(bytes: 4567, etag: "\"v1\"")))
        #expect(!first.matches(DiskTileCache.Stamp(bytes: 4568, etag: "\"v1\"")))
        #expect(!first.matches(second))
        #expect(DiskTileCache.Stamp(bytes: nil, etag: "\"v1\"").merged(with: DiskTileCache.Stamp(bytes: 10, etag: "\"v9\"")) == DiskTileCache.Stamp(bytes: 10, etag: "\"v1\""))
    }

    @Test("Version d'un fichier distant : une réponse d'une autre version est refusée, une fois signalée")
    func remoteVersion() throws {
        // connue par le manifeste (taille seule), puis complétée par l'ETag de la première réponse
        let version = RemoteFileVersion(known: DiskTileCache.Stamp(bytes: 4567, etag: nil))
        try version.observe(etag: "\"v1\"", total: 4567)
        try version.observe(etag: "\"v1\"", total: nil)
        try version.observe(etag: nil, total: 4567)
        #expect(version.stamp == DiskTileCache.Stamp(bytes: 4567, etag: "\"v1\""))
        #expect(!version.takeChanged())

        // le fichier est republié : même taille, autre ETag
        #expect(throws: TileFileChanged.self) { try version.observe(etag: "\"v2\"", total: 4567) }
        #expect(version.takeChanged())
        #expect(!version.takeChanged())
        #expect(version.stamp == nil)
        // la réponse suivante fait foi
        try version.observe(etag: "\"v2\"", total: 4567)
        #expect(version.stamp == DiskTileCache.Stamp(bytes: 4567, etag: "\"v2\""))
        // autre taille
        #expect(throws: TileFileChanged.self) { try version.observe(etag: nil, total: 5000) }

        // rien de connu d'avance : la première réponse fait foi ; un serveur muet ne bloque rien
        let unknown = RemoteFileVersion(known: nil)
        try unknown.observe(etag: nil, total: nil)
        try unknown.observe(etag: "\"x\"", total: 12)
        #expect(unknown.stamp == DiskTileCache.Stamp(bytes: 12, etag: "\"x\""))
    }

    @Test("TileStore : au changement de manifeste, le cache d'un fichier dont la taille a changé est écarté")
    func configureDiscardsStaleFiles() async throws {
        let cache = try Self.temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.root) }
        let manifest = try Fixtures.decode(TilesManifest.self, Fixtures.manifestJSON)
        let terrain = "T-boletus_edulis-af34c16e-p1.0.0-da1b2c3.pmtiles"  // 123456 octets au manifeste
        let altitude = "A-300m-da1b2c3.pmtiles"  // 4567 octets au manifeste
        try cache.write(file: terrain, z: 12, x: 1, y: 1, data: Data([1]), stamp: DiskTileCache.Stamp(bytes: 123_456, etag: "\"t\""))
        try cache.write(file: altitude, z: 12, x: 1, y: 1, data: Data([2]), stamp: DiskTileCache.Stamp(bytes: 4000, etag: "\"a\""))

        let store = TileStore(disk: cache)
        let palette = try PointInspectorTests.palette()
        let api = StubURLProtocol.api(host: StubURLProtocol.host())
        await store.configure(manifest: manifest, api: api, scoringVersion: "1.0.0", palette: palette)
        #expect(cache.read(file: terrain, z: 12, x: 1, y: 1) == .tile(Data([1])))  // même version : gardé
        #expect(cache.read(file: altitude, z: 12, x: 1, y: 1) == .miss)  // republié : écarté
        #expect(cache.files() == [terrain])
    }

    @Test("TileStore : une tuile lue une fois reste lisible sans la source (hors ligne)")
    func storeUsesDisk() async throws {
        let cache = try Self.temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.root) }
        let t = TileMath.tile(lon: PointInspectorTests.longitude, lat: PointInspectorTests.latitude, z: 15)
        let png = try PointInspectorTests.tile([(t.py * TileMath.tileSize + t.px, 254)])
        let file = PointInspectorTests.pmtiles(tiles: [(t.x, t.y, png)])

        let online = TileStore(disk: cache)
        await online.install(terrain: ["boletus_edulis": PMTilesReader(source: MemorySource(data: file))], alt: nil)
        let first = try await online.terrainTile(species: "boletus_edulis", z: 15, x: t.x, y: t.y)
        #expect(first?.width == TileMath.tileSize)
        #expect(try await online.terrainTile(species: "boletus_edulis", z: 15, x: t.x + 1, y: t.y) == nil)
        #expect(cache.read(file: "T-boletus_edulis", z: 15, x: t.x, y: t.y) == .tile(png))
        #expect(cache.read(file: "T-boletus_edulis", z: 15, x: t.x + 1, y: t.y) == .absent)

        // Même cache, source vide : la tuile et son absence viennent du disque.
        let offline = TileStore(disk: cache)
        await offline.install(terrain: ["boletus_edulis": PMTilesReader(source: MemorySource(data: Data()))], alt: nil)
        let again = try await offline.terrainTile(species: "boletus_edulis", z: 15, x: t.x, y: t.y)
        #expect(again == first)
        #expect(try await offline.terrainTile(species: "boletus_edulis", z: 15, x: t.x + 1, y: t.y) == nil)
        #expect(await offline.diskSize() == Int64(png.count))

        try await offline.clearDisk()
        #expect(await offline.diskSize() == 0)
        await #expect(throws: (any Error).self) {
            try await offline.terrainTile(species: "boletus_edulis", z: 15, x: t.x, y: t.y)
        }
    }
}
