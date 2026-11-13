import ChampisPMTiles
import ChampisScoring
import Foundation
import Testing
@testable import Champis

/// Source en mémoire qui compte ses lectures : autant de requêtes Range partiraient sur le réseau.
actor CountingSource: TileSource {
    let data: Data
    private(set) var reads = 0

    init(data: Data) {
        self.data = data
    }

    func read(offset: UInt64, length: Int) async throws -> Data {
        reads += 1
        let start = Int(offset)
        guard start + length <= data.count else { throw PMTilesError.truncated("mémoire") }
        return data.subdata(in: start..<(start + length))
    }
}

/// Choix des fichiers PMTiles à lire en ligne d'après le manifeste `GET /tiles` (`TileStore.chooseEntries`),
/// et lecture des PMTiles par groupe `G` (spec › Points ouverts › Les clients lisent les PMTiles par
/// groupe, 5 nov. 2026) : un canal par espèce, une lecture par tuile partagée entre les espèces.
struct TileStoreManifestTests {
    static let size = TileMath.tileSize
    static let cepes = ["boletus_aereus", "boletus_edulis", "boletus_pinophilus", "boletus_reticulatus"]

    static func entry(
        kind: String, name: String, species: String? = nil, scoring: String? = "1.0.0", dept: String? = nil,
        deptsHash: String? = nil, group: String? = nil, channels: [String]? = nil, part: Int? = nil
    ) -> TilesManifest.Entry {
        TilesManifest.Entry(
            kind: kind, name: name, url: "/tiles/" + name, bytes: 1, species: species, hash: "fe88e376",
            scoringVersion: scoring, deptsHash: deptsHash, classM: kind == "A" ? 300 : nil, dept: dept,
            group: group, channels: channels, part: part
        )
    }

    static func palette() throws -> Palette {
        try Palette.decode(Data(Fixtures.paletteJSON.utf8))
    }

    // MARK: PNG RGBA écrit octet par octet

    static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// PNG RGBA 8 bits non entrelacé, filtre 0 sur chaque ligne, flux zlib : le quatrième canal porte
    /// une donnée, jamais une transparence, ce que `TileImage.png` (CGImage, alpha prémultiplié) ne
    /// garantit pas. Le format exact des `G` du pipeline.
    static func rgbaPNG(_ rgba: [UInt8], size: Int) throws -> Data {
        precondition(rgba.count == size * size * 4)
        var raw: [UInt8] = []
        raw.reserveCapacity(size * (size * 4 + 1))
        for y in 0..<size {
            raw.append(0)
            raw.append(contentsOf: rgba[(y * size * 4)..<((y + 1) * size * 4)])
        }
        let deflated = [UInt8](try (Data(raw) as NSData).compressed(using: .zlib) as Data)
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in raw {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let zlib = [0x78, 0x9C] + deflated + be32(b << 16 | a)
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let typed = Array(type.utf8) + body
            return be32(UInt32(body.count)) + typed + be32(crc32(typed))
        }
        let ihdr = be32(UInt32(size)) + be32(UInt32(size)) + [8, 6, 0, 0, 0]  // 8 bits, RGBA, non entrelacé
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        return Data(signature + chunk("IHDR", ihdr) + chunk("IDAT", zlib) + chunk("IEND", []))
    }

    /// Tuile `G` : pixels donnés sous forme (index, quatre canaux), `255` partout ailleurs (nodata).
    static func groupTile(_ pixels: [(i: Int, c: [UInt8])]) throws -> Data {
        var rgba = [UInt8](repeating: 255, count: size * size * 4)
        for p in pixels {
            for k in 0..<4 { rgba[p.i * 4 + k] = p.c[k] }
        }
        return try rgbaPNG(rgba, size: size)
    }

    // MARK: Manifeste

    @Test("Entrée G du manifeste : group, species en tableau (ordre des canaux), part absente ; réécrite à l'identique")
    func groupEntryDecoding() throws {
        let manifest = try Fixtures.decode(TilesManifest.self, Fixtures.manifestGroupsJSON)
        let g = try #require(manifest.tiles.first { $0.kind == "G" && $0.dept == nil })
        #expect(g.isGroup)
        #expect(g.group == "cepes")
        #expect(g.species == nil)
        #expect(g.channels == ["boletus_aereus", "boletus_edulis"])
        #expect(g.coveredSpecies == ["boletus_aereus", "boletus_edulis"])
        #expect(g.part == nil)
        #expect(g.hash == "c0ffee00" && g.scoringVersion == "1.0.0" && g.deptsHash == "a1b2c3")
        #expect(g.name == "G-cepes-c0ffee00-p1.0.0-da1b2c3.pmtiles")
        let t = try #require(manifest.tiles.first { $0.kind == "T" && $0.species == "boletus_edulis" && $0.dept == nil })
        #expect(!t.isGroup && t.channels == nil && t.group == nil)
        #expect(t.coveredSpecies == ["boletus_edulis"])
        #expect(manifest.tiles.first { $0.kind == "A" }?.coveredSpecies.isEmpty == true)

        // le manifeste est gardé sur disque pour démarrer sans réseau : aller-retour sans perte
        let again = try JSONDecoder().decode(TilesManifest.self, from: JSONEncoder().encode(manifest))
        #expect(again.tiles == manifest.tiles)

        // seconde partie d'un groupe de plus de quatre espèces
        let part = try Fixtures.decode(
            TilesManifest.Entry.self,
            #"{"kind": "G", "group": "cepes", "species": ["x"], "part": 2, "name": "G-cepes-aa-p1.0.0-dbb-2.pmtiles", "url": "/tiles/g"}"#
        )
        #expect(part.part == 2 && part.channels == ["x"])
    }

    @Test("Le jeu complet (sans dept) passe avant un jeu par département, même si ce dernier vient après par nom")
    func fullSetBeatsDepartmentSets() {
        let tiles = [
            Self.entry(kind: "T", name: "T-boletus_edulis-fe88e376-p1.0.0-d7bb9d4.pmtiles", species: "boletus_edulis"),
            Self.entry(kind: "T", name: "T-boletus_edulis-fe88e376-p1.0.0-dff5a1a.pmtiles", species: "boletus_edulis", dept: "70"),
            Self.entry(kind: "T", name: "T-boletus_edulis-fe88e376-p1.0.0-db7a568.pmtiles", species: "boletus_edulis", dept: "25"),
            Self.entry(kind: "A", name: "A-300m-d7bb9d4.pmtiles"),
            Self.entry(kind: "A", name: "A-300m-dff5a1a.pmtiles", dept: "70"),
        ]
        let chosen = TileStore.chooseEntries(tiles, scoringVersion: "1.0.0")
        #expect(chosen.terrain["boletus_edulis"]?.name == "T-boletus_edulis-fe88e376-p1.0.0-d7bb9d4.pmtiles")
        #expect(chosen.alt?.name == "A-300m-d7bb9d4.pmtiles")
        #expect(chosen.groups.isEmpty)
    }

    @Test("Version de scoring de l'app préférée ; à défaut, le dernier nom ; les entrées inconnues ignorées")
    func scoringVersionThenName() {
        let tiles = [
            Self.entry(kind: "T", name: "T-cantharellus_cibarius-9e6a9da6-p1.1.0-d7bb9d4.pmtiles", species: "cantharellus_cibarius", scoring: "1.1.0"),
            Self.entry(kind: "T", name: "T-cantharellus_cibarius-9e6a9da6-p1.0.0-d7bb9d4.pmtiles", species: "cantharellus_cibarius"),
            Self.entry(kind: "T", name: "T-boletus_edulis-aaaaaaaa-p1.0.0-d111111.pmtiles", species: "boletus_edulis"),
            Self.entry(kind: "T", name: "T-boletus_edulis-bbbbbbbb-p1.0.0-d222222.pmtiles", species: "boletus_edulis"),
            Self.entry(kind: "T", name: "T-sans-espece.pmtiles"),
            Self.entry(kind: "X", name: "X-inconnu.pmtiles", species: "boletus_edulis"),
        ]
        let chosen = TileStore.chooseEntries(tiles, scoringVersion: "1.0.0")
        #expect(chosen.terrain["cantharellus_cibarius"]?.name == "T-cantharellus_cibarius-9e6a9da6-p1.0.0-d7bb9d4.pmtiles")
        #expect(chosen.terrain["boletus_edulis"]?.name == "T-boletus_edulis-bbbbbbbb-p1.0.0-d222222.pmtiles")
        #expect(chosen.terrain.count == 2)
        #expect(chosen.alt == nil)
    }

    @Test("Sans jeu complet (manifeste d'un seul département), le jeu par département est lu")
    func departmentOnlyManifest() {
        let tiles = [
            Self.entry(kind: "T", name: "T-boletus_edulis-fe88e376-p1.0.0-db7a568.pmtiles", species: "boletus_edulis", dept: "25"),
            Self.entry(kind: "A", name: "A-300m-db7a568.pmtiles", dept: "25"),
        ]
        let chosen = TileStore.chooseEntries(tiles, scoringVersion: "1.0.0")
        #expect(chosen.terrain["boletus_edulis"]?.dept == "25")
        #expect(chosen.alt?.dept == "25")
    }

    @Test("G : le jeu complet est choisi avant celui d'un département, les T restent choisis (repli), un G d'un autre jeu est écarté")
    func groupsChosen() throws {
        let manifest = try Fixtures.decode(TilesManifest.self, Fixtures.manifestGroupsJSON)
        let chosen = TileStore.chooseEntries(manifest.tiles, scoringVersion: "1.0.0")
        #expect(chosen.groups.map(\.name) == ["G-cepes-c0ffee00-p1.0.0-da1b2c3.pmtiles"])
        #expect(chosen.groups.first?.dept == nil)
        #expect(chosen.terrain.keys.sorted() == ["boletus_aereus", "boletus_edulis", "cantharellus_cibarius"])
        #expect(chosen.terrain.values.allSatisfy { $0.dept == nil })
        #expect(chosen.alt?.name == "A-300m-da1b2c3.pmtiles")

        // sans G (la production d'aujourd'hui) : rien ne change pour les T
        let withoutGroups = TileStore.chooseEntries(manifest.tiles.filter { $0.kind != "G" }, scoringVersion: "1.0.0")
        #expect(withoutGroups.groups.isEmpty)
        #expect(withoutGroups.terrain.count == 3)

        // un G d'un autre jeu (hash de départements ou version de scoring) que les T choisis : écarté
        let otherSet = Self.entry(
            kind: "G", name: "G-cepes-c0ffee00-p1.0.0-d999999.pmtiles", deptsHash: "999999", group: "cepes",
            channels: ["boletus_aereus", "boletus_edulis"]
        )
        let stale = TileStore.chooseEntries(manifest.tiles.filter { $0.kind != "G" } + [otherSet], scoringVersion: "1.0.0")
        #expect(stale.groups.isEmpty)
        let otherVersion = Self.entry(
            kind: "G", name: "G-cepes-c0ffee00-p1.1.0-da1b2c3.pmtiles", scoring: "1.1.0", deptsHash: "a1b2c3", group: "cepes",
            channels: ["boletus_aereus", "boletus_edulis"]
        )
        #expect(TileStore.chooseEntries(manifest.tiles.filter { $0.kind != "G" } + [otherVersion], scoringVersion: "1.0.0").groups.isEmpty)

        // un G sans espèces ou sans groupe est ignoré ; une seconde partie est gardée à côté de la première
        let empty = Self.entry(kind: "G", name: "G-vide-aa-p1.0.0-da1b2c3.pmtiles", deptsHash: "a1b2c3", group: "vide", channels: [])
        let noGroup = Self.entry(kind: "G", name: "G-sans-aa-p1.0.0-da1b2c3.pmtiles", deptsHash: "a1b2c3", channels: ["x"])
        let part2 = Self.entry(
            kind: "G", name: "G-cepes-c0ffee00-p1.0.0-da1b2c3-2.pmtiles", deptsHash: "a1b2c3", group: "cepes", channels: ["boletus_pinophilus"], part: 2
        )
        let parts = TileStore.chooseEntries(manifest.tiles + [empty, noGroup, part2], scoringVersion: "1.0.0")
        #expect(parts.groups.map(\.name) == ["G-cepes-c0ffee00-p1.0.0-da1b2c3-2.pmtiles", "G-cepes-c0ffee00-p1.0.0-da1b2c3.pmtiles"])
    }

    // MARK: Canaux

    @Test("Canal d'une tuile G : gris = canal de l'espèce, alpha 0 sur nodata ; 4e canal d'un groupe de 3 ignoré")
    func channelExtraction() throws {
        let palette = try Self.palette()
        let encoding = try #require(palette.groupTileEncoding)
        #expect(encoding.channels == "rgba" && encoding.scale == 254 && encoding.nodata == 255)

        // pixel 0 : quatre valeurs ; pixel 1 : nodata sur le 2e canal ; pixel 2 : rien (255 partout)
        let data = try Self.groupTile([(0, [254, 127, 10, 100]), (1, [40, 255, 0, 3])])
        let png = try PNGDecoder.decode(data)
        #expect(png.width == Self.size && png.height == Self.size && png.channels == 4)
        #expect(Array(png.data[0..<4]) == [254, 127, 10, 100])
        #expect(Array(png.data[4..<8]) == [40, 255, 0, 3])

        let first = try #require(GroupTile.channel(png, index: 0, encoding: encoding, tileEncoding: palette.tileEncoding))
        #expect(first.channels == 2 && first.width == Self.size && first.data.count == Self.size * Self.size * 2)
        #expect(first.data[0] == 254 && first.data[1] == 255)
        #expect(first.data[2] == 40 && first.data[3] == 255)
        #expect(first.data[5] == 0)  // pixel 2 : nodata, transparent
        let second = try #require(GroupTile.channel(png, index: 1, encoding: encoding, tileEncoding: palette.tileEncoding))
        #expect(second.data[0] == 127 && second.data[1] == 255)
        #expect(second.data[3] == 0)  // nodata pour cette espèce
        let fourth = try #require(GroupTile.channel(png, index: 3, encoding: encoding, tileEncoding: palette.tileEncoding))
        #expect(fourth.data[0] == 100 && fourth.data[1] == 255)  // l'alpha est une donnée
        #expect(fourth.data[2] == 3 && fourth.data[3] == 255)
        #expect(GroupTile.channel(png, index: 4, encoding: encoding, tileEncoding: palette.tileEncoding) == nil)
        #expect(GroupTile.channel(first, index: 0, encoding: encoding, tileEncoding: palette.tileEncoding) == nil)  // pas une tuile G

        // le coloriste lit le canal extrait comme un T : T = gris / 254, nodata transparent
        let colorizer = TileColorizer(palette: palette)
        #expect(colorizer.terrain(first, at: 0) == 1.0)
        #expect(colorizer.terrain(second, at: 0).map { abs($0 - 0.5) < 1e-9 } == true)
        #expect(colorizer.terrain(second, at: 1) == nil)
        #expect(colorizer.terrain(first, at: 2) == nil)
    }

    // MARK: Lectures

    static func fixtureTile() -> (x: Int, y: Int, i: Int) {
        let t = TileMath.tile(lon: PointInspectorTests.longitude, lat: PointInspectorTests.latitude, z: 15)
        return (t.x, t.y, t.py * size + t.px)
    }

    @Test("Couche de quatre espèces : une tuile = une lecture du G et une de A, le canal de chaque espèce")
    func oneReadPerGroupTile() async throws {
        let palette = try Self.palette()
        let (x, y, i) = Self.fixtureTile()
        let groupData = PointInspectorTests.pmtiles(tiles: [(x, y, try Self.groupTile([(i, [254, 127, 255, 40])]))])
        let altData = PointInspectorTests.pmtiles(tiles: [(x, y, try PointInspectorTests.tile([(i, 1)]))])

        func store(species: [String]) async -> (TileStore, CountingSource, CountingSource) {
            let g = CountingSource(data: groupData)
            let a = CountingSource(data: altData)
            let store = TileStore()
            await store.install(
                terrain: [:], groups: [TileStore.GroupFile(name: "G-cepes", reader: PMTilesReader(source: g), species: species)],
                alt: PMTilesReader(source: a), palette: palette
            )
            return (store, g, a)
        }

        let weather = try PointInspectorTests.weather()
        func render(_ store: TileStore, members: [String]) async throws -> RenderedTile {
            let renderer = TileRenderer(store: store)
            renderer.update(RenderSettings(
                layer: Layer(key: .group("cepes"), title: "Cèpes", members: members), mode: .score, date: "2026-10-30",
                weather: weather, colorizer: TileColorizer(palette: palette)
            ))
            return try await renderer.render(z: 15, x: x, y: y)
        }

        // une espèce seule : la référence
        let (single, g1, a1) = await store(species: Self.cepes)
        #expect(await single.groupedSpecies == Set(Self.cepes))
        #expect(await single.species == Set(Self.cepes))
        #expect(try await render(single, members: ["boletus_edulis"]).image != nil)
        let baselineG = await g1.reads
        let baselineA = await a1.reads
        #expect(baselineG > 0 && baselineA > 0)

        // les quatre espèces du groupe : pas une lecture de plus, ni sur le G ni sur A
        let (four, g4, a4) = await store(species: Self.cepes)
        #expect(try await render(four, members: Self.cepes).image != nil)
        #expect(await g4.reads == baselineG)
        #expect(await a4.reads == baselineA)

        // relire espèce par espèce : la tuile décodée est en cache, le canal de chacune en sort
        let edulis = try #require(try await four.terrainTile(species: "boletus_edulis", z: 15, x: x, y: y))
        #expect(edulis.channels == 2 && edulis.data[i * 2] == 127 && edulis.data[i * 2 + 1] == 255)
        let aereus = try #require(try await four.terrainTile(species: "boletus_aereus", z: 15, x: x, y: y))
        #expect(aereus.data[i * 2] == 254)
        let pinophilus = try #require(try await four.terrainTile(species: "boletus_pinophilus", z: 15, x: x, y: y))
        #expect(pinophilus.data[i * 2 + 1] == 0)  // nodata pour cette espèce : transparent
        let reticulatus = try #require(try await four.terrainTile(species: "boletus_reticulatus", z: 15, x: x, y: y))
        #expect(reticulatus.data[i * 2] == 40 && reticulatus.data[i * 2 + 1] == 255)
        #expect(await g4.reads == baselineG)
        // tuile hors du G : nil sans retomber sur un T
        #expect(try await four.terrainTile(species: "boletus_edulis", z: 15, x: x + 3, y: y) == nil)
        // espèce hors du groupe et sans T : nil
        #expect(try await four.terrainTile(species: "cantharellus_cibarius", z: 15, x: x, y: y) == nil)
    }

    @Test("Sans group_tile_encoding (vieille API), le G est ignoré et le T lu")
    func legacyPaletteFallsBackToTerrain() async throws {
        let legacy = try Palette.decode(Data(Fixtures.legacyPaletteJSON.utf8))
        #expect(legacy.groupTileEncoding == nil)
        let (x, y, i) = Self.fixtureTile()
        let group = PMTilesReader(source: MemorySource(data: PointInspectorTests.pmtiles(tiles: [(x, y, try Self.groupTile([(i, [254, 254, 254, 254])]))])))
        let terrain = PMTilesReader(source: MemorySource(data: PointInspectorTests.pmtiles(tiles: [(x, y, try PointInspectorTests.tile([(i, 100)]))])))
        let store = TileStore()
        await store.install(
            terrain: ["boletus_edulis": terrain], groups: [TileStore.GroupFile(name: "G-cepes", reader: group, species: ["boletus_edulis"])],
            alt: nil, palette: legacy
        )
        let png = try #require(try await store.terrainTile(species: "boletus_edulis", z: 15, x: x, y: y))
        #expect(png.channels == 4 && png.data[i * 4] == 100)  // le T, pas le canal du G

        // avec l'encodage, le même manifeste lit le G
        let modern = TileStore()
        await modern.install(
            terrain: ["boletus_edulis": terrain], groups: [TileStore.GroupFile(name: "G-cepes", reader: group, species: ["boletus_edulis"])],
            alt: nil, palette: try Self.palette()
        )
        let fromGroup = try #require(try await modern.terrainTile(species: "boletus_edulis", z: 15, x: x, y: y))
        #expect(fromGroup.channels == 2 && fromGroup.data[i * 2] == 254)
    }

    @Test("Hors ligne : le G embarqué passe avant la source distante, un département en T reste lisible")
    func localGroupFiles() async throws {
        let root = OfflineStoreTests.temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (x, y, i) = Self.fixtureTile()
        let groupURL = root.appending(path: "G-cepes-local.pmtiles")
        try PointInspectorTests.pmtiles(tiles: [(x, y, try Self.groupTile([(i, [11, 22, 255, 255])]))]).write(to: groupURL)
        let terrainURL = root.appending(path: "T-cantharellus_cibarius-local.pmtiles")
        try PointInspectorTests.pmtiles(tiles: [(x, y, try PointInspectorTests.tile([(i, 200)]))]).write(to: terrainURL)

        let store = TileStore()
        // source distante vide : toute lecture distante échoue
        let broken = PMTilesReader(source: MemorySource(data: Data()))
        await store.install(
            terrain: ["boletus_edulis": broken, "boletus_aereus": broken, "cantharellus_cibarius": broken],
            groups: [TileStore.GroupFile(name: "G-cepes", reader: broken, species: ["boletus_aereus", "boletus_edulis"])],
            alt: nil, palette: try Self.palette()
        )
        await store.setLocalFiles([
            OfflineLocalFile(kind: "G", species: nil, url: groupURL, channels: ["boletus_aereus", "boletus_edulis"]),
            OfflineLocalFile(kind: "T", species: "cantharellus_cibarius", url: terrainURL),
        ])
        #expect(await store.hasLocalFiles)
        let edulis = try #require(try await store.terrainTile(species: "boletus_edulis", z: 15, x: x, y: y))
        #expect(edulis.channels == 2 && edulis.data[i * 2] == 22)
        let aereus = try #require(try await store.terrainTile(species: "boletus_aereus", z: 15, x: x, y: y))
        #expect(aereus.data[i * 2] == 11)
        let cibarius = try #require(try await store.terrainTile(species: "cantharellus_cibarius", z: 15, x: x, y: y))
        #expect(cibarius.data[i * 4] == 200)
        // hors du département embarqué et sans réseau : nil, pas d'erreur
        #expect(try await store.terrainTile(species: "boletus_edulis", z: 15, x: x + 5, y: y) == nil)
        // sans fichier local, la panne distante remonte
        await store.setLocalFiles([])
        let stillLocal = await store.hasLocalFiles
        #expect(!stillLocal)
        await #expect(throws: (any Error).self) {
            try await store.terrainTile(species: "boletus_edulis", z: 15, x: x, y: y)
        }
    }

    @Test("Tuile A réécrite en tranches de 20 m : chaque pixel au centre de sa classe, inconnu conservé")
    func classTileAsFineIndices() throws {
        let palette = try WeatherFieldTests.finePalette()
        let elev = try #require(palette.elevEncoding)
        // quatre pixels gris + alpha : classes 0, 1 et 4, puis un pixel inconnu (alpha 0), puis nodata
        let png = DecodedPNG(width: 5, height: 1, channels: 2, data: [0, 255, 1, 255, 4, 255, 2, 0, 255, 255])
        let fine = TileStore.fineIndices(fromClasses: png, alt: palette.altEncoding, elev: elev)
        #expect(fine.channels == 2 && fine.width == 5 && fine.height == 1)
        // 150 m → tranche 7, 450 m → 22, 1 350 m → 67 ; milieu de tranche = centre de classe
        #expect(fine.data == [7, 255, 22, 255, 67, 255, 255, 0, 255, 0])
        #expect(CellInterpolation.elevation(index: 22, stepM: elev.stepM) == 450)
    }

    @Test("Manifeste : la couche E est choisie à côté de la couche A, jeu complet d'abord")
    func elevationEntry() throws {
        let tiles = [
            Self.entry(kind: "A", name: "A-300m-da1b2c3.pmtiles", scoring: nil, deptsHash: "a1b2c3"),
            Self.entry(kind: "E", name: "E-20m-d222222.pmtiles", scoring: nil, dept: "25", deptsHash: "222222"),
            Self.entry(kind: "E", name: "E-20m-da1b2c3.pmtiles", scoring: nil, deptsHash: "a1b2c3"),
        ]
        let chosen = TileStore.chooseEntries(tiles, scoringVersion: "1.0.0")
        #expect(chosen.alt?.name == "A-300m-da1b2c3.pmtiles")
        #expect(chosen.elev?.name == "E-20m-da1b2c3.pmtiles")
        #expect(TileStore.chooseEntries([tiles[0]], scoringVersion: "1.0.0").elev == nil)
    }
}
