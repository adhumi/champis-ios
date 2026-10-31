import ChampisPMTiles
import Foundation
import Testing
@testable import Champis

struct OfflineStoreTests {
    static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "champis-offline-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static func department(code: String = "25") -> OfflineDepartment {
        OfflineDepartment(
            code: code, name: "Doubs", species: ["boletus_edulis"],
            files: [
                OfflineFile(name: "T-boletus_edulis-af34c16e-p1.0.0-d111111.pmtiles", kind: "T", species: "boletus_edulis", url: "https://api.test/tiles/T", bytes: 0, done: false),
                OfflineFile(name: "A-300m-d111111.pmtiles", kind: "A", species: nil, url: "https://api.test/tiles/A", bytes: 0, done: false),
            ],
            weatherToday: nil, weatherFetchedAt: nil, tilesGenerated: "2026-10-31T03:00:00Z", scoringVersion: "1.0.0", error: nil
        )
    }

    @Test("Un département n'est complet qu'avec tous ses fichiers et sa météo ; tout est relu du disque")
    func lifecycle() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineStore(root: root)
        try await store.load()
        #expect(await store.departments.isEmpty)
        #expect(await store.localFiles().isEmpty)

        try await store.begin(Self.department())
        var department = try #require(await store.department("25"))
        #expect(!department.filesDone && !department.complete)
        #expect(await store.localFiles().isEmpty)  // incomplet : rien n'est exposé

        try await store.markDone(code: "25", name: department.files[0].name, bytes: 100)
        try await store.markDone(code: "25", name: department.files[1].name, bytes: 50)
        department = try #require(await store.department("25"))
        #expect(department.filesDone && !department.complete)
        #expect(department.bytes == 150)

        let weather = try Fixtures.decode(WeatherBBoxResponse.self, Fixtures.weatherJSON)
        try await store.saveWeather(code: "25", responses: [weather, weather], fetchedAt: "2026-10-31T08:00:00Z")
        department = try #require(await store.department("25"))
        #expect(department.complete)
        #expect(department.weatherToday == "2026-10-30")
        #expect(try await store.weather(code: "25").count == 2)
        #expect(await store.allWeather().count == 2)
        let files = await store.localFiles()
        #expect(files.map(\.kind) == ["T", "A"])
        #expect(files[0].species == "boletus_edulis" && files[1].species == nil)
        #expect(files[0].url.lastPathComponent == department.files[0].name)
        #expect(await store.totalBytes == 150)

        let again = OfflineStore(root: root)
        try await again.load()
        #expect(await again.department("25")?.complete == true)
        try await again.markError(code: "25", "test")
        #expect(await again.department("25")?.error == "test")
        try await again.remove(code: "25")
        #expect(await again.departments.isEmpty)
        let removed = await again.directory(for: "25")
        #expect(!FileManager.default.fileExists(atPath: removed.path(percentEncoded: false)))
    }

    @Test("Caches de démarrage : espèces et manifeste relus sans réseau")
    func caches() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineStore(root: root)
        #expect(await store.cachedCatalog() == nil)
        try await store.saveCatalog(try Fixtures.decode(SpeciesCatalog.self, Fixtures.catalogJSON))
        try await store.saveTilesManifest(try Fixtures.decode(TilesManifest.self, Fixtures.manifestJSON))
        #expect(await store.cachedCatalog()?.species.count == 3)
        #expect(await store.cachedTilesManifest()?.tiles.count == 2)
    }

    @Test("Emprise découpée sous la limite de cellules de /weather/bbox")
    func split() {
        let bbox = BBox(minLon: 5.7, minLat: 46.5, maxLon: 7.1, maxLat: 47.6)
        let parts = bbox.split(maxSpan: 0.3)
        #expect(parts.count == 5 * 4)
        #expect(parts.allSatisfy { $0.maxLon - $0.minLon <= 0.3 + 1e-9 && $0.maxLat - $0.minLat <= 0.3 + 1e-9 })
        #expect(abs((parts.last?.maxLon ?? 0) - 7.1) < 1e-9 && abs((parts.last?.maxLat ?? 0) - 47.6) < 1e-9)
        #expect(abs((parts.first?.minLon ?? 0) - 5.7) < 1e-9 && abs((parts.first?.minLat ?? 0) - 46.5) < 1e-9)
        #expect(BBox(minLon: 0, minLat: 0, maxLon: 0.1, maxLat: 0.1).split(maxSpan: 0.3).count == 1)
    }

    @Test("Départements téléchargeables : les entrées `dept` du manifeste, par code")
    func downloadable() throws {
        let manifest = try Fixtures.decode(TilesManifest.self, Fixtures.manifestPerDeptJSON)
        let choices = OfflineModel.downloadable(from: manifest, names: ["25": "Doubs"])
        #expect(choices.map(\.code) == ["25", "39"])
        #expect(choices[0].title == "Doubs (25)")
        #expect(choices[1].title == "Département 39")
        #expect(choices[0].terrain.keys.sorted() == ["boletus_aereus", "boletus_edulis"])
        #expect(choices[0].altitude?.name == "A-300m-d222222.pmtiles")
        #expect(choices[1].altitude == nil)
        #expect(choices[0].bytes(for: ["boletus_edulis"]) == 1000 + 300)
        #expect(choices[0].bytes(for: ["boletus_edulis", "boletus_aereus"]) == 1000 + 2000 + 300)
    }

    @Test("Lecteur de tuiles : les fichiers embarqués passent avant la source distante, même sans réseau")
    func localFirst() async throws {
        let root = Self.temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let t = TileMath.tile(lon: PointInspectorTests.longitude, lat: PointInspectorTests.latitude, z: 15)
        let png = try PointInspectorTests.tile([(t.py * TileMath.tileSize + t.px, 200)])
        let local = root.appending(path: "T-local.pmtiles")
        try PointInspectorTests.pmtiles(tiles: [(t.x, t.y, png)]).write(to: local)

        let store = TileStore()
        // source distante vide : toute lecture distante échoue
        await store.install(terrain: ["boletus_edulis": PMTilesReader(source: MemorySource(data: Data()))], alt: nil)
        await store.setLocalFiles([OfflineLocalFile(kind: "T", species: "boletus_edulis", url: local)])
        #expect(await store.hasLocalFiles)
        let tile = try await store.terrainTile(species: "boletus_edulis", z: 15, x: t.x, y: t.y)
        #expect(tile?.data[(t.py * TileMath.tileSize + t.px) * 4] == 200)
        // hors du département embarqué et sans réseau : nil, pas d'erreur
        #expect(try await store.terrainTile(species: "boletus_edulis", z: 15, x: t.x + 5, y: t.y) == nil)
        // sans fichier local, la même panne remonte
        await store.setLocalFiles([])
        await #expect(throws: (any Error).self) {
            try await store.terrainTile(species: "boletus_edulis", z: 15, x: t.x, y: t.y)
        }
    }
}

@MainActor
struct OfflineModelTests {
    @Test("Téléchargement d'un département : fichiers, météo par sous-emprises, puis disponible")
    func download() async throws {
        let root = OfflineStoreTests.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let t = TileMath.tile(lon: PointInspectorTests.longitude, lat: PointInspectorTests.latitude, z: 15)
        let pmtiles = PointInspectorTests.pmtiles(tiles: [(t.x, t.y, try PointInspectorTests.tile([(0, 254)]))])

        let host = StubURLProtocol.host()
        StubURLProtocol.set(host: host, binary: { _, path in path.hasPrefix("/tiles/") ? pmtiles : nil }) { _, path, _ in
            path == "/weather/bbox" ? (200, Fixtures.weatherJSON) : (404, #"{"detail": "inconnu"}"#)
        }
        let api = StubURLProtocol.api(host: host)
        let store = OfflineStore(root: root)
        let downloads = DownloadManager(configuration: StubURLProtocol.configuration())
        let model = OfflineModel(api: api, store: store, downloads: downloads)
        var published: [[OfflineLocalFile]] = []
        model.onLocalFilesChanged = { files in published.append(files) }
        await model.start(api: api)

        let manifest = try Fixtures.decode(TilesManifest.self, Fixtures.manifestPerDeptJSON)
        let choice = try #require(OfflineModel.downloadable(from: manifest, names: [:]).first { $0.code == "25" })
        await model.download(choice, species: ["boletus_edulis"], manifest: manifest, scoringVersion: "1.0.0")
        #expect(model.departments.count == 1)

        for _ in 0..<100 where model.departments.first?.complete != true {
            try await Task.sleep(for: .milliseconds(100))
        }
        let department = try #require(model.departments.first)
        #expect(department.complete, "\(department.error ?? "") \(model.status ?? "")")
        #expect(department.files.count == 2)
        #expect(department.weatherToday == "2026-10-30")
        #expect(StubURLProtocol.requests(host: host).filter { $0.path == "/weather/bbox" }.count >= 1)
        #expect(published.last?.count == 2)
        #expect(try await store.weather(code: "25").isEmpty == false)

        await model.delete(code: "25")
        #expect(model.departments.isEmpty)
        #expect(published.last?.isEmpty == true)
    }
}
