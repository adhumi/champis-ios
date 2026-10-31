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
