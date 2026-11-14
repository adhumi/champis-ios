import Foundation
import Testing
@testable import Champis

/// Traversée de chemin depuis le manifeste `GET /tiles` (audit du 13 nov. 2026) : `dept` et `name`
/// servent de dossier et de fichier sur l'appareil.
struct SafePathTests {
    @Test("Code de département : deux ou trois chiffres, 2A, 2B", arguments: ["01", "25", "95", "2A", "2B", "971", "100"])
    func departments(code: String) {
        #expect(SafePath.isDepartment(code))
    }

    @Test("Code de département refusé", arguments: ["", "1", "2a", "2C", "A2", "1234", "..", "../25", "25/", "25/..", "２５", " 25", "2A ", "25\n"])
    func notDepartments(code: String) {
        #expect(!SafePath.isDepartment(code))
    }

    @Test("Nom de fichier du manifeste : un composant sûr en .pmtiles", arguments: [
        "T-boletus_edulis-af34c16e-p1.0.0-da1b2c3.pmtiles", "A-300m-da1b2c3.pmtiles", "E-20m-d222222.pmtiles",
        "G-cepes-c0ffee00-p1.0.0-da1b2c3-2.pmtiles",
    ])
    func fileNames(name: String) {
        #expect(SafePath.isTileFileName(name))
        #expect(SafePath.isComponent(name))
    }

    @Test("Nom de fichier refusé", arguments: [
        "", ".pmtiles", "..", "../x.pmtiles", "a/b.pmtiles", "a\\b.pmtiles", "x..pmtiles", "..x.pmtiles", "T-x.pmtiles/",
        "T-x.PMTILES", "T-x.pmtiles.json", "T x.pmtiles", "T-é.pmtiles", "/etc/passwd", "T-x.pmtiles\0", "%2e%2e.pmtiles",
    ])
    func notFileNames(name: String) {
        #expect(!SafePath.isTileFileName(name))
    }

    @Test("Composant de chemin : ni vide, ni point, ni remontée")
    func components() {
        #expect(SafePath.isComponent("T-boletus_edulis"))
        #expect(SafePath.isComponent("A"))
        for name in ["", ".", "..", "a/b", "a..b", "local:T-x.pmtiles", "a b", String(repeating: "a", count: 201)] {
            #expect(!SafePath.isComponent(name), "\(name)")
        }
    }

    @Test("Destination standardisée : strictement sous la racine, sans consulter le disque")
    func containment() throws {
        let root = URL(filePath: "/tmp/champis/offline", directoryHint: .isDirectory)
        #expect(SafePath.isContained(root.appending(path: "25/T-x.pmtiles"), in: root))
        #expect(SafePath.isContained(root.appending(path: "25/../39/weather.json"), in: root))
        #expect(SafePath.isContained(URL(filePath: "/tmp/./champis/offline/25"), in: root))
        #expect(!SafePath.isContained(root, in: root))
        #expect(!SafePath.isContained(root.appending(path: "25/.."), in: root))
        #expect(!SafePath.isContained(root.appending(path: "../field/coins.json"), in: root))
        #expect(!SafePath.isContained(root.appending(path: "25/../../../etc/passwd"), in: root))
        #expect(!SafePath.isContained(URL(filePath: "/tmp/champis/offline-autre/25"), in: root))
        #expect(!SafePath.isContained(URL(filePath: "/../../.."), in: root))
        #expect(!SafePath.isContained(URL(string: "https://champis.app/tmp/champis/offline/25")!, in: root))
        #expect(try SafePath.checked(root.appending(path: "25"), in: root) == root.appending(path: "25"))
        #expect(throws: SafePath.Refused.self) { try SafePath.checked(root.appending(path: "../x"), in: root) }
    }

    @Test("Manifeste : une entrée au nom ou au département invalide est ignorée, les autres restent")
    func manifestSkipsUnsafeEntries() throws {
        let manifest = try Fixtures.decode(TilesManifest.self, """
        {
          "configured": true, "mode": "proxy", "generated": "2026-11-13T03:00:00Z",
          "tiles": [
            { "kind": "A", "class_m": 300, "depts_hash": "a1b2c3", "name": "A-300m-da1b2c3.pmtiles", "bytes": 10, "url": "/tiles/A-300m-da1b2c3.pmtiles" },
            { "kind": "A", "class_m": 300, "depts_hash": "a1b2c3", "name": "../../field/coins.json", "bytes": 10, "url": "/tiles/x" },
            { "kind": "A", "class_m": 300, "depts_hash": "a1b2c3", "name": "A-300m-da1b2c3.pmtiles/../../x.pmtiles", "bytes": 10, "url": "/tiles/x" },
            { "kind": "A", "class_m": 300, "depts_hash": "222222", "dept": "../..", "name": "A-300m-d222222.pmtiles", "bytes": 10, "url": "/tiles/x" },
            { "kind": "A", "class_m": 300, "depts_hash": "222222", "dept": "25/../../field", "name": "A-300m-d222222.pmtiles", "bytes": 10, "url": "/tiles/x" },
            { "kind": "A", "class_m": 300, "depts_hash": "222222", "dept": "2B", "name": "A-300m-d222222.pmtiles", "bytes": 10, "url": "/tiles/A-300m-d222222.pmtiles" },
            { "kind": "A" },
            42
          ]
        }
        """)
        #expect(manifest.configured)
        #expect(manifest.tiles.map(\.name) == ["A-300m-da1b2c3.pmtiles", "A-300m-d222222.pmtiles"])
        #expect(manifest.tiles.map(\.dept) == [nil, "2B"])
        // les manifestes de référence se lisent en entier, et se relisent après écriture (cache de démarrage)
        let reference = try Fixtures.decode(TilesManifest.self, Fixtures.manifestGroupsJSON)
        let again = try JSONDecoder().decode(TilesManifest.self, from: JSONEncoder().encode(reference))
        #expect(again.tiles == reference.tiles && !reference.tiles.isEmpty)
        #expect(again.generated == reference.generated && again.mode == reference.mode)
    }

    @Test("Cache des tuiles : un nom qui sort de la racine n'est ni lu, ni écrit")
    func diskCacheRefusesTraversal() throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "champis-safe-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        let cache = DiskTileCache(root: parent.appending(path: "tiles", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: cache.root, withIntermediateDirectories: true)
        for name in ["../dehors", "..", "a/b", ""] {
            #expect(throws: SafePath.Refused.self, "\(name)") {
                try cache.write(file: name, z: 1, x: 2, y: 3, data: Data([1]))
            }
            #expect(cache.read(file: name, z: 1, x: 2, y: 3) == .miss)
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: parent.path(percentEncoded: false))) == ["tiles"])
        #expect(cache.files().isEmpty)
    }

    @Test("Départements embarqués : un code ou un nom qui sort de la racine n'écrit rien et n'efface rien")
    func offlineStoreRefusesTraversal() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "champis-safe-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appending(path: "offline", directoryHint: .isDirectory)
        let neighbour = parent.appending(path: "field", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: neighbour, withIntermediateDirectories: true)
        try Data("privé".utf8).write(to: neighbour.appending(path: "coins.json"))
        let store = OfflineStore(root: root)
        try await store.load()

        let unsafeCode = OfflineStoreTests.department(code: "../field")
        await #expect(throws: SafePath.Refused.self) { try await store.begin(unsafeCode) }
        let unsafeName = OfflineDepartment(
            code: "25", name: "Doubs", species: ["boletus_edulis"],
            files: [OfflineFile(name: "../../field/coins.json", kind: "T", species: "boletus_edulis", url: "https://api.test/x", bytes: 0, done: false)],
            weatherToday: nil, weatherFetchedAt: nil, tilesGenerated: nil, scoringVersion: nil, error: nil
        )
        await #expect(throws: SafePath.Refused.self) { try await store.begin(unsafeName) }
        #expect(await store.departments.isEmpty)
        await #expect(throws: SafePath.Refused.self) { try await store.fileURL(code: "25", name: "../x.pmtiles") }
        await #expect(throws: SafePath.Refused.self) { try await store.fileURL(code: "..", name: "A-300m-d111111.pmtiles") }
        #expect(try await store.fileURL(code: "25", name: "A-300m-d111111.pmtiles").lastPathComponent == "A-300m-d111111.pmtiles")

        // supprimer un code qui remonte : le dossier voisin reste
        try await store.remove(code: "../field")
        #expect(FileManager.default.fileExists(atPath: neighbour.appending(path: "coins.json").path(percentEncoded: false)))
    }
}
