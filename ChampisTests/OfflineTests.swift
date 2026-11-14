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

    @Test("Avec des G par département : le G du groupe et A, le T des seules espèces sans G ; taille = somme des fichiers retenus")
    func downloadableWithGroups() throws {
        let manifest = try Fixtures.decode(TilesManifest.self, Fixtures.manifestGroupsJSON)
        let choices = OfflineModel.downloadable(from: manifest, names: [:])
        #expect(choices.map(\.code) == ["25"])
        let doubs = try #require(choices.first)
        #expect(doubs.groups.map(\.name) == ["G-cepes-c0ffee00-p1.0.0-d222222.pmtiles"])
        #expect(doubs.species == ["boletus_aereus", "boletus_edulis", "cantharellus_cibarius"])
        #expect(doubs.altitude?.name == "A-300m-d222222.pmtiles")

        // une seule espèce du groupe : son G entier plutôt que son T
        #expect(doubs.files(for: ["boletus_edulis"]).map(\.name) == ["G-cepes-c0ffee00-p1.0.0-d222222.pmtiles", "A-300m-d222222.pmtiles"])
        #expect(doubs.bytes(for: ["boletus_edulis"]) == 2500 + 300)
        // espèce sans G : son T
        #expect(doubs.files(for: ["cantharellus_cibarius"]).map(\.kind) == ["T", "A"])
        #expect(doubs.bytes(for: ["cantharellus_cibarius"]) == 1500 + 300)
        // tout : G, T de la girolle, A ; jamais deux fois le G
        let all = doubs.files(for: doubs.species)
        #expect(all.map(\.kind) == ["G", "T", "A"])
        #expect(all[1].species == "cantharellus_cibarius")
        #expect(doubs.bytes(for: doubs.species) == 2500 + 1500 + 300)
        #expect(doubs.files(for: []).map(\.kind) == ["A"])

        // sans G dans le manifeste : les T, comme avant
        let plain = try #require(OfflineModel.downloadable(from: try Fixtures.decode(TilesManifest.self, Fixtures.manifestPerDeptJSON), names: [:]).first)
        #expect(plain.groups.isEmpty)
        #expect(plain.files(for: ["boletus_edulis", "boletus_aereus"]).map(\.kind) == ["T", "T", "A"])
    }

    @Test("Un fichier G embarqué garde ses espèces (ordre des canaux) jusqu'au lecteur de tuiles")
    func groupFileRoundTrip() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineStore(root: root)
        try await store.load()
        var department = Self.department()
        department.files = [
            OfflineFile(
                name: "G-cepes-c0ffee00-p1.0.0-d111111.pmtiles", kind: "G", species: nil, url: "https://api.test/tiles/G", bytes: 0, done: false,
                channels: ["boletus_aereus", "boletus_edulis"]
            ),
            OfflineFile(name: "A-300m-d111111.pmtiles", kind: "A", species: nil, url: "https://api.test/tiles/A", bytes: 0, done: false),
        ]
        try await store.begin(department)
        try await store.markDone(code: "25", name: department.files[0].name, bytes: 10)
        try await store.markDone(code: "25", name: department.files[1].name, bytes: 5)
        try await store.saveWeather(code: "25", responses: [try Fixtures.decode(WeatherBBoxResponse.self, Fixtures.weatherJSON)], fetchedAt: "2026-11-05T08:00:00Z")

        let again = OfflineStore(root: root)
        try await again.load()
        let files = await again.localFiles()
        #expect(files.map(\.kind) == ["G", "A"])
        #expect(files[0].channels == ["boletus_aereus", "boletus_edulis"] && files[0].species == nil)
        #expect(files[1].channels == nil)
        // un offline.json d'avant les G (sans `channels`) se relit
        let legacy = try JSONDecoder().decode(OfflineFile.self, from: Data(#"{"name": "T-x.pmtiles", "kind": "T", "species": "x", "url": "u", "bytes": 1, "done": true}"#.utf8))
        #expect(legacy.channels == nil && legacy.species == "x")
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
    /// `manifestPerDeptJSON` dont les fichiers du département 25 retenus pour le cèpe de Bordeaux
    /// (son `T`, 1000 octets, et la couche `A`, 300 octets) annoncent `bytes`.
    static func manifest(bytes: Int) -> String {
        Fixtures.manifestPerDeptJSON
            .replacingOccurrences(of: "\"bytes\": 1000,", with: "\"bytes\": \(bytes),")
            .replacingOccurrences(of: "\"bytes\": 300,", with: "\"bytes\": \(bytes),")
    }

    /// Écrit l'emprise dans l'en-tête d'un PMTiles (degrés × 10⁷, entiers 32 bits petit-boutistes, octet 102).
    static func withBounds(_ pmtiles: Data, minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) -> Data {
        var data = pmtiles
        for (index, degrees) in [minLon, minLat, maxLon, maxLat].enumerated() {
            let value = UInt32(bitPattern: Int32((degrees * 1e7).rounded()))
            for byte in 0..<4 {
                data[102 + index * 4 + byte] = UInt8((value >> (8 * UInt32(byte))) & 0xFF)
            }
        }
        return data
    }

    @Test("Météo embarquée : l'emprise de l'en-tête est bornée à la France avant d'être découpée")
    func weatherBounds() {
        // un département : inchangé
        let doubs = OfflineModel.weatherBounds(minLon: 5.7, minLat: 46.5, maxLon: 7.1, maxLat: 47.6)
        #expect(doubs == BBox(minLon: 5.7, minLat: 46.5, maxLon: 7.1, maxLat: 47.6))
        // en-tête aberrant (le monde entier, ou les bornes d'un entier 32 bits) : la France, pas plus
        let world = OfflineModel.weatherBounds(minLon: -180, minLat: -85, maxLon: 180, maxLat: 85)
        #expect(world == BBox.france)
        #expect(OfflineModel.weatherBounds(minLon: -214.7, minLat: -214.7, maxLon: 214.7, maxLat: 214.7) == BBox.france)
        let parts = BBox.france.split(maxSpan: OfflineModel.weatherSpan)
        #expect(parts.count == 52 * 35)
        // hors de France, retournée ou non finie : rien
        #expect(OfflineModel.weatherBounds(minLon: 0, minLat: 0, maxLon: 0, maxLat: 0) == nil)
        #expect(OfflineModel.weatherBounds(minLon: 20, minLat: 45, maxLon: 25, maxLat: 48) == nil)
        #expect(OfflineModel.weatherBounds(minLon: 7, minLat: 47, maxLon: 5, maxLat: 46) == nil)
        #expect(OfflineModel.weatherBounds(minLon: .nan, minLat: 46, maxLon: 7, maxLat: 47) == nil)
        #expect(OfflineModel.weatherBounds(minLon: -.infinity, minLat: 46, maxLon: .infinity, maxLat: 47) == nil)
        // le découpage lui-même ne boucle pas sur une emprise aberrante
        #expect(BBox(minLon: -180, minLat: -85, maxLon: 180, maxLat: 85).split(maxSpan: 0.3).isEmpty)
        #expect(BBox(minLon: 5, minLat: 46, maxLon: .infinity, maxLat: 47).split(maxSpan: 0.3).isEmpty)
        #expect(BBox(minLon: 5, minLat: 46, maxLon: 7, maxLat: 47).split(maxSpan: 0).isEmpty)
        #expect(BBox(minLon: 5, minLat: 46, maxLon: 7, maxLat: 47).split(maxSpan: 1e-9).isEmpty)
        #expect(BBox(minLon: 7, minLat: 46, maxLon: 5, maxLat: 47).split(maxSpan: 0.3).isEmpty)
    }

    @Test("Fichier reçu d'une autre taille que celle du manifeste : département incomplet, en clair")
    func sizeMismatch() async throws {
        #expect(OfflineModel.sizeMismatch(name: "A.pmtiles", received: 10, expected: 10) == nil)
        #expect(OfflineModel.sizeMismatch(name: "A.pmtiles", received: 10, expected: 0) == nil)  // taille non annoncée
        #expect(OfflineModel.sizeMismatch(name: "A.pmtiles", received: 9, expected: 10) == "A.pmtiles : 9 octets reçus, 10 annoncés par le manifeste")

        let root = OfflineStoreTests.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pmtiles = PointInspectorTests.pmtiles(tiles: [(1, 1, try PointInspectorTests.tile([(0, 254)]))])
        let host = StubURLProtocol.host()
        StubURLProtocol.set(host: host, binary: { _, path in path.hasPrefix("/tiles/") ? pmtiles : nil }) { _, path, _ in
            path == "/weather/bbox" ? (200, Fixtures.weatherJSON) : (404, #"{"detail": "inconnu"}"#)
        }
        let api = StubURLProtocol.api(host: host)
        let store = OfflineStore(root: root)
        let model = OfflineModel(api: api, store: store, downloads: DownloadManager(configuration: StubURLProtocol.configuration()))
        await model.start(api: api)

        // le manifeste annonce un octet de plus que ce que le serveur envoie (jeu republié entre-temps)
        let manifest = try Fixtures.decode(TilesManifest.self, Self.manifest(bytes: pmtiles.count + 1))
        let choice = try #require(OfflineModel.downloadable(from: manifest, names: [:]).first { $0.code == "25" })
        await model.download(choice, species: ["boletus_edulis"], manifest: manifest, scoringVersion: "1.0.0")
        for _ in 0..<100 where model.problem == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        let problem = try #require(model.problem)
        #expect(problem.text == "Département 25 incomplet : un fichier reçu n'a pas la taille annoncée")
        #expect(problem.detail?.contains("annoncés par le manifeste") == true)
        let department = try #require(model.departments.first)
        #expect(!department.complete && !department.filesDone)
        #expect(department.weatherToday == nil)
        #expect(await store.localFiles().isEmpty)
        #expect(StubURLProtocol.requests(host: host).filter { $0.path == "/weather/bbox" }.isEmpty)
    }

    @Test("Téléchargement d'un département : fichiers, météo par sous-emprises, puis disponible")
    func download() async throws {
        let root = OfflineStoreTests.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let t = TileMath.tile(lon: PointInspectorTests.longitude, lat: PointInspectorTests.latitude, z: 15)
        // l'emprise de l'en-tête sert à demander la météo : celle d'un département (5,5–7,2 E, 46,5–47,8 N)
        let pmtiles = Self.withBounds(
            PointInspectorTests.pmtiles(tiles: [(t.x, t.y, try PointInspectorTests.tile([(0, 254)]))]),
            minLon: 5.5, minLat: 46.5, maxLon: 7.2, maxLat: 47.8
        )

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

        // le manifeste annonce la taille réelle des fichiers servis (contrôlée après téléchargement)
        let manifest = try Fixtures.decode(TilesManifest.self, Self.manifest(bytes: pmtiles.count))
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
