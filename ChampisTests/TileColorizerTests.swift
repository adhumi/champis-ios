import ChampisPMTiles
import ChampisScoring
import Foundation
import Testing
@testable import Champis

/// La fonction de couleur est testée sans MapKit, contre les seuils exacts de la palette et sur les
/// cas limites : nodata, alpha 0, cellule absente, classe d'altitude inconnue, groupe.
struct TileColorizerTests {
    static let size = TileMath.tileSize
    // Tuile 6/33/22 : son centre (47,04 N, 8,44 E) est tout près de la cellule c_1 de la fixture.
    static let z = 6, x = 33, y = 22

    static func palette() throws -> Palette {
        try Palette.decode(Data(Fixtures.paletteJSON.utf8))
    }

    static func weather() throws -> WeatherField {
        var field = WeatherField()
        field.merge(try Fixtures.decode(WeatherBBoxResponse.self, Fixtures.weatherJSON))
        return field
    }

    /// Tuile gris + alpha, transparente partout sauf aux pixels donnés.
    static func tile(_ pixels: [(i: Int, v: UInt8, a: UInt8)]) -> DecodedPNG {
        var data = [UInt8](repeating: 0, count: size * size * 2)
        for p in pixels {
            data[p.i * 2] = p.v
            data[p.i * 2 + 1] = p.a
        }
        return DecodedPNG(width: size, height: size, channels: 2, data: data)
    }

    static func request(
        mode: MapMode, date: String?, tiles: [TileColorizer.SpeciesTile], alt: DecodedPNG? = nil,
        weather: WeatherField = WeatherField()
    ) -> TileColorizer.Request {
        TileColorizer.Request(z: z, x: x, y: y, mode: mode, date: date, tiles: tiles, alt: alt, weather: weather)
    }

    static func rgba(_ bytes: [UInt8], at i: Int) -> RGBA {
        RGBA(r: bytes[i * 4], g: bytes[i * 4 + 1], b: bytes[i * 4 + 2], a: bytes[i * 4 + 3])
    }

    @Test("Hex de la palette : #RRGGBB, #RRGGBBAA, invalide")
    func hex() {
        #expect(RGBA(hex: "#1B6B3A") == RGBA(r: 0x1B, g: 0x6B, b: 0x3A, a: 255))
        #expect(RGBA(hex: "#00000000") == .clear)
        #expect(RGBA(hex: "E88A3C") == RGBA(r: 0xE8, g: 0x8A, b: 0x3C, a: 255))
        #expect(RGBA(hex: "#zzzzzz") == nil)
        #expect(RGBA(hex: "#123") == nil)
    }

    @Test("Seuils exacts : 0,75 excellent, 0,55 bon, 0,35 moyen, 0,15 faible, sinon très faible")
    func thresholds() throws {
        let colorizer = TileColorizer(palette: try Self.palette())
        let excellent = RGBA(hex: "#1B6B3A"), bon = RGBA(hex: "#4CA64C"), moyen = RGBA(hex: "#E3C64B")
        let faible = RGBA(hex: "#E88A3C"), tresFaible = RGBA(hex: "#B8402E")
        #expect(colorizer.color(for: 1.0) == excellent)
        #expect(colorizer.color(for: 0.75) == excellent)
        #expect(colorizer.color(for: 0.7499) == bon)
        #expect(colorizer.color(for: 0.55) == bon)
        #expect(colorizer.color(for: 0.5499) == moyen)
        #expect(colorizer.color(for: 0.35) == moyen)
        #expect(colorizer.color(for: 0.3499) == faible)
        #expect(colorizer.color(for: 0.15) == faible)
        #expect(colorizer.color(for: 0.1499) == tresFaible)
        #expect(colorizer.color(for: 0) == tresFaible)
    }

    @Test("Mode terrain : T = gris / 254 ; alpha 0 et nodata 255 transparents")
    func terrain() throws {
        let colorizer = TileColorizer(palette: try Self.palette())
        let tile = Self.tile([(0, 254, 255), (1, 0, 0), (2, 255, 255), (3, 127, 255), (4, 39, 255)])
        #expect(colorizer.terrain(tile, at: 0) == 1.0)
        #expect(colorizer.terrain(tile, at: 1) == nil)
        #expect(colorizer.terrain(tile, at: 2) == nil)
        #expect(colorizer.terrain(tile, at: 3).map { abs($0 - 0.5) < 1e-9 } == true)

        let request = Self.request(mode: .terrain, date: nil, tiles: [.init(species: "boletus_edulis", png: tile)])
        let values = colorizer.values(request)
        #expect(values[0] == 1.0)
        #expect(values[1].isNaN && values[2].isNaN && values[5].isNaN)
        let bytes = try #require(colorizer.render(request))
        #expect(bytes.count == Self.size * Self.size * 4)
        #expect(Self.rgba(bytes, at: 0) == RGBA(hex: "#1B6B3A"))
        #expect(Self.rgba(bytes, at: 1) == .clear)
        #expect(Self.rgba(bytes, at: 2) == .clear)
        #expect(Self.rgba(bytes, at: 3) == RGBA(hex: "#E3C64B"))
        #expect(Self.rgba(bytes, at: 4) == RGBA(hex: "#E88A3C"))  // 39 / 254 ≈ 0,154
        #expect(colorizer.render(Self.request(mode: .terrain, date: nil, tiles: [])) == nil)
    }

    @Test("Mode score : S = T × M_eff × Φ de la cellule la plus proche ; sans météo, transparent")
    func score() throws {
        let colorizer = TileColorizer(palette: try Self.palette())
        let tile = Self.tile([(0, 254, 255), (3, 127, 255)])
        let layer = [TileColorizer.SpeciesTile(species: "boletus_edulis", png: tile)]

        let weather = try Self.weather()

        // Sans couche A : altitude médiane 620 m → classe 450 → M_eff × Φ = 0,9
        let values = colorizer.values(Self.request(mode: .score, date: "2026-10-30", tiles: layer, weather: weather))
        #expect(abs(values[0] - 0.9) < 1e-9)
        #expect(abs(values[3] - 0.45) < 1e-9)
        #expect(values[1].isNaN)

        // J+1 : 0,6 pour les deux classes
        let tomorrow = colorizer.values(Self.request(mode: .score, date: "2026-10-31", tiles: layer, weather: weather))
        #expect(abs(tomorrow[0] - 0.6) < 1e-9)

        // Pas de météo du tout, ou pas ce jour-là : jamais un 0,5 inventé
        let noWeather = colorizer.values(Self.request(mode: .score, date: "2026-10-30", tiles: layer))
        let otherDay = colorizer.values(Self.request(mode: .score, date: "2026-12-01", tiles: layer, weather: weather))
        let noDate = colorizer.values(Self.request(mode: .score, date: nil, tiles: layer, weather: weather))
        #expect(noWeather.allSatisfy(\.isNaN))
        #expect(otherDay.allSatisfy(\.isNaN))
        #expect(noDate.allSatisfy(\.isNaN))
    }

    @Test("Couche A : classe du pixel ; nodata ou alpha 0 → repli sur la médiane de la cellule")
    func altitudeLayer() throws {
        let colorizer = TileColorizer(palette: try Self.palette())
        let tile = Self.tile([(0, 254, 255), (1, 254, 255), (2, 254, 255), (3, 254, 255)])
        // pixel 0 : classe 0 (150 m) → 0,5 ; pixel 1 : nodata → repli 450 → 0,9 ; pixel 2 : alpha 0 → repli ; pixel 3 : classe 1 → 0,9
        let alt = Self.tile([(0, 0, 255), (1, 255, 255), (2, 7, 0), (3, 1, 255)])
        #expect(colorizer.altitudeClass(alt, at: 0) == 0)
        #expect(colorizer.altitudeClass(alt, at: 1) == nil)
        #expect(colorizer.altitudeClass(alt, at: 2) == nil)
        #expect(colorizer.altitudeClass(alt, at: 3) == 1)

        let request = Self.request(
            mode: .score, date: "2026-10-30", tiles: [.init(species: "boletus_edulis", png: tile)], alt: alt,
            weather: try Self.weather()
        )
        let values = colorizer.values(request)
        #expect(abs(values[0] - 0.5) < 1e-9)
        #expect(abs(values[1] - 0.9) < 1e-9)
        #expect(abs(values[2] - 0.9) < 1e-9)
        #expect(abs(values[3] - 0.9) < 1e-9)
    }

    @Test("Groupe : max des espèces, en terrain comme en score (règle 9)")
    func group() throws {
        let colorizer = TileColorizer(palette: try Self.palette())
        let edulis = TileColorizer.SpeciesTile(species: "boletus_edulis", png: Self.tile([(0, 127, 255)]))
        let aereus = TileColorizer.SpeciesTile(species: "boletus_aereus", png: Self.tile([(0, 254, 255), (1, 254, 255)]))
        let terrain = colorizer.values(Self.request(mode: .terrain, date: nil, tiles: [edulis, aereus]))
        #expect(terrain[0] == 1.0)
        #expect(terrain[1] == 1.0)
        // score : edulis 0,5 × 0,9 = 0,45 ; aereus 1,0 × 0,2 = 0,2 → 0,45
        let score = colorizer.values(Self.request(mode: .score, date: "2026-10-30", tiles: [edulis, aereus], weather: try Self.weather()))
        #expect(abs(score[0] - 0.45) < 1e-9)
        #expect(abs(score[1] - 0.2) < 1e-9)
    }

    @Test("Encodage PNG de la tuile colorisée : taille attendue, tuile vide valide")
    func encode() throws {
        let colorizer = TileColorizer(palette: try Self.palette())
        let request = Self.request(mode: .terrain, date: nil, tiles: [.init(species: "boletus_edulis", png: Self.tile([(0, 254, 255)]))])
        let rgba = try #require(colorizer.render(request))
        let png = try #require(TileImage.png(rgba: rgba, size: Self.size))
        #expect(Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        let decoded = try PNGDecoder.decode(png)
        #expect(decoded.width == Self.size && decoded.height == Self.size && decoded.channels == 4)
        #expect(decoded.data[3] == 255 && decoded.data[7] == 0)  // pixel 0 opaque, pixel 1 transparent
        #expect(!TileImage.empty.isEmpty)
        #expect(TileImage.png(rgba: [0, 0, 0], size: Self.size) == nil)
    }
}
