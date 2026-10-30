import ChampisPMTiles
import ChampisScoring
import Foundation
import Testing
@testable import Champis

/// Fichier PMTiles en mémoire (en-tête, racine sans compression, tuiles PNG), lu par le lecteur
/// maison à travers `TileStore`, pour exercer la fiche sans réseau.
nonisolated struct MemorySource: TileSource {
    let data: Data

    func read(offset: UInt64, length: Int) async throws -> Data {
        let start = Int(offset)
        guard start + length <= data.count else { throw PMTilesError.truncated("mémoire") }
        return data.subdata(in: start..<(start + length))
    }
}

struct PointInspectorTests {
    static let size = TileMath.tileSize
    static let latitude = 47.04
    static let longitude = 8.4375
    static let layer = Layer(key: .species("boletus_edulis"), title: "Cèpe de Bordeaux", members: ["boletus_edulis"])

    static func palette() throws -> Palette {
        try Palette.decode(Data(Fixtures.paletteJSON.utf8))
    }

    static func weather() throws -> WeatherField {
        var field = WeatherField()
        field.merge(try Fixtures.decode(WeatherBBoxResponse.self, Fixtures.weatherJSON))
        return field
    }

    /// PMTiles v3 minimal : en-tête 127 octets, répertoire racine, données contiguës, zoom 15 seul.
    static func pmtiles(tiles: [(x: Int, y: Int, png: Data)]) -> Data {
        var entries: [DirectoryEntry] = []
        var data = Data()
        for t in tiles.sorted(by: { TileID.fromZXY(z: 15, x: $0.x, y: $0.y) < TileID.fromZXY(z: 15, x: $1.x, y: $1.y) }) {
            entries.append(DirectoryEntry(
                tileID: TileID.fromZXY(z: 15, x: t.x, y: t.y), offset: UInt64(data.count), length: UInt32(t.png.count), runLength: 1
            ))
            data += t.png
        }
        let root = Directory.serialize(entries)
        var header = [UInt8](repeating: 0, count: 127)
        header.replaceSubrange(0..<7, with: Array("PMTiles".utf8))
        header[7] = 3
        func put(_ v: UInt64, at: Int) {
            for i in 0..<8 { header[at + i] = UInt8((v >> (8 * UInt64(i))) & 0xFF) }
        }
        let rootOffset = UInt64(127)
        put(rootOffset, at: 8)
        put(UInt64(root.count), at: 16)
        put(rootOffset + UInt64(root.count), at: 56)
        put(UInt64(data.count), at: 64)
        header[97] = 1  // internal_compression none
        header[98] = 1  // tile_compression none
        header[99] = 2  // png
        header[100] = 15
        header[101] = 15
        return Data(header) + root + data
    }

    /// Tuile RGBA dont le premier canal porte la valeur et le dernier l'alpha (le coloriste lit les
    /// deux de la même façon qu'un gris + alpha) ; transparente partout sauf aux pixels donnés.
    static func tile(_ pixels: [(i: Int, v: UInt8)]) throws -> Data {
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        for p in pixels {
            rgba[p.i * 4] = p.v
            rgba[p.i * 4 + 3] = 255
        }
        return try #require(TileImage.png(rgba: rgba, size: size))
    }

    static func store(altClass: UInt8?) async throws -> TileStore {
        let t = TileMath.tile(lon: longitude, lat: latitude, z: PointInspector.zoom)
        let i = t.py * size + t.px
        let terrain = pmtiles(tiles: [(t.x, t.y, try tile([(i, 254), (i == 0 ? 1 : 0, 127)]))])
        let store = TileStore()
        var alt: PMTilesReader?
        if let altClass {
            alt = PMTilesReader(source: MemorySource(data: pmtiles(tiles: [(t.x, t.y, try tile([(i, altClass)]))])))
        }
        await store.install(terrain: ["boletus_edulis": PMTilesReader(source: MemorySource(data: terrain))], alt: alt)
        return store
    }

    static func settings(mode: MapMode, weather: WeatherField) throws -> RenderSettings {
        RenderSettings(layer: layer, mode: mode, date: "2026-10-30", weather: weather, colorizer: TileColorizer(palette: try palette()))
    }

    @Test("Mode terrain : T du pixel et classe d'altitude de la couche A")
    func terrain() async throws {
        let store = try await Self.store(altClass: 1)
        let info = try await PointInspector.inspect(
            latitude: Self.latitude, longitude: Self.longitude, settings: try Self.settings(mode: .terrain, weather: WeatherField()), store: store
        )
        let scored = try #require(info.scored)
        #expect(scored.species == "boletus_edulis")
        #expect(scored.terrain == 1.0)
        #expect(scored.value == 1.0)
        #expect(scored.factor == nil)
        #expect(scored.altClass == 1)
        #expect(scored.cell == nil)
        #expect(info.mode == .terrain)
    }

    @Test("Mode score : S = T × M_eff × Φ de la cellule la plus proche, classe du pixel")
    func score() async throws {
        let store = try await Self.store(altClass: 1)
        let info = try await PointInspector.inspect(
            latitude: Self.latitude, longitude: Self.longitude, settings: try Self.settings(mode: .score, weather: try Self.weather()), store: store
        )
        let scored = try #require(info.scored)
        #expect(abs(scored.value - 0.9) < 1e-9)
        #expect(scored.altKey == "450")
        #expect(scored.altFallback == false)
        #expect(scored.cell?.id == "c_1")
        #expect(scored.row?.mEff == 0.9)
        #expect(info.date == "2026-10-30")
    }

    @Test("Sans couche A : repli sur l'altitude médiane de la cellule, dit tel quel")
    func fallback() async throws {
        let store = try await Self.store(altClass: nil)
        let info = try await PointInspector.inspect(
            latitude: Self.latitude, longitude: Self.longitude, settings: try Self.settings(mode: .score, weather: try Self.weather()), store: store
        )
        let scored = try #require(info.scored)
        #expect(scored.altClass == nil)
        #expect(scored.altKey == "450")
        #expect(scored.altFallback == true)
        #expect(abs(scored.value - 0.9) < 1e-9)
    }

    @Test("Du terrain sans météo → « pas de météo » ; hors emprise → « pas de donnée »")
    func missing() async throws {
        let store = try await Self.store(altClass: 1)
        let noWeather = try await PointInspector.inspect(
            latitude: Self.latitude, longitude: Self.longitude, settings: try Self.settings(mode: .score, weather: WeatherField()), store: store
        )
        #expect(noWeather.isNoWeather)
        let elsewhere = try await PointInspector.inspect(
            latitude: 45.0, longitude: 3.0, settings: try Self.settings(mode: .terrain, weather: WeatherField()), store: store
        )
        #expect(elsewhere.isNoData)
        let noLayer = try await PointInspector.inspect(
            latitude: Self.latitude, longitude: Self.longitude, settings: RenderSettings(), store: store
        )
        #expect(noLayer.isNoData)
    }
}
