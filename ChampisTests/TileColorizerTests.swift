import ChampisPMTiles
import ChampisScoring
import Foundation
import Testing
@testable import Champis

/// La fonction de couleur est testée sans MapKit, contre l'échelle linéaire de la palette (alpha =
/// score, arrondi floor(x + 0,5)) et sur les cas limites : nodata, alpha 0, cellule absente, classe
/// d'altitude inconnue, groupe, palette ancienne sans échelle.
struct TileColorizerTests {
    static let size = TileMath.tileSize
    // Tuile 15/17148/11525 : elle contient la cellule c_1 de la fixture (47,0 N, 8,4 E), tous ses
    // pixels sont à moins de 1,5 km, donc sous la borne de 7,5 km de l'index spatial.
    static let z = 15, x = 17148, y = 11525

    static func palette() throws -> Palette {
        try Palette.decode(Data(Fixtures.paletteJSON.utf8))
    }

    static func weather() throws -> WeatherField {
        var field = WeatherField()
        field.merge(try Fixtures.decode(WeatherBBoxResponse.self, Fixtures.weatherJSON))
        return field
    }

    /// La même cellule par le champ compact `/weather/field` (sous le zoom 9).
    static func compactWeather() throws -> WeatherField {
        var field = WeatherField()
        field.merge(try Fixtures.decode(WeatherFieldResponse.self, Fixtures.weatherFieldJSON))
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

    /// Le violet de l'échelle de la fixture (`#633179`) avec l'alpha donné.
    static func violet(_ a: UInt8) -> RGBA { RGBA(r: 99, g: 49, b: 121, a: a) }

    @Test("Échelle linéaire : un seul violet, l'alpha est le score, arrondi floor(x + 0,5), borné à [0, 1]")
    func linearScale() throws {
        let colorizer = TileColorizer(palette: try Self.palette())
        #expect(colorizer.color(for: 0) == Self.violet(0))
        #expect(colorizer.color(for: 0.5 / 255) == Self.violet(1))  // 1, là où un arrondi au pair donnerait 0
        #expect(colorizer.color(for: 0.5) == Self.violet(128))  // 127,5 → 128
        #expect(colorizer.color(for: 0.75) == Self.violet(191))
        #expect(colorizer.color(for: 1.0) == Self.violet(255))
        #expect(colorizer.color(for: -0.2) == Self.violet(0))
        #expect(colorizer.color(for: 1.5) == Self.violet(255))
        // même résultat que le paquet, validé par les vecteurs de parité
        let fixture = try Self.palette()
        let px = try #require(fixture.pixelColor(0.37))
        #expect(colorizer.color(for: 0.37) == RGBA(r: px.r, g: px.g, b: px.b, a: px.a))
    }

    @Test("Palette sans échelle (API ancienne) : couleur de la classe, seuils exacts")
    func withoutScale() throws {
        let colorizer = TileColorizer(palette: try Palette.decode(Data(Fixtures.legacyPaletteJSON.utf8)))
        let tresFaible = RGBA(hex: "#B8402E")
        #expect(colorizer.color(for: 1.0) == tresFaible)
        #expect(colorizer.color(for: 0) == tresFaible)
        let request = Self.request(mode: .terrain, date: nil, tiles: [.init(species: "boletus_edulis", png: Self.tile([(0, 254, 255)]))])
        let bytes = try #require(colorizer.render(request))
        #expect(Self.rgba(bytes, at: 0) == tresFaible)
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
        #expect(Self.rgba(bytes, at: 0) == Self.violet(255))
        #expect(Self.rgba(bytes, at: 1) == .clear)
        #expect(Self.rgba(bytes, at: 2) == .clear)
        #expect(Self.rgba(bytes, at: 3) == Self.violet(128))  // 127 / 254 = 0,5 → 127,5 + 0,5 → 128
        #expect(Self.rgba(bytes, at: 4) == Self.violet(39))  // 39 / 254 ≈ 0,154 → 39,15 + 0,5 → 39
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
        let allTransparent = [noWeather, otherDay, noDate].map { values in values.allSatisfy { $0.isNaN } }
        #expect(allTransparent == [true, true, true])
    }

    @Test("Champ compact : mêmes couleurs que /weather/bbox, f appliqué à T, un seul jour")
    func compactField() throws {
        let colorizer = TileColorizer(palette: try Self.palette())
        let tile = Self.tile([(0, 254, 255), (3, 127, 255)])
        let layer = [TileColorizer.SpeciesTile(species: "boletus_edulis", png: tile)]
        let alt = Self.tile([(0, 0, 255), (3, 1, 255)])
        let compact = try Self.compactWeather()
        let full = try Self.weather()

        let fromField = colorizer.values(Self.request(mode: .score, date: "2026-10-30", tiles: layer, alt: alt, weather: compact))
        let fromBBox = colorizer.values(Self.request(mode: .score, date: "2026-10-30", tiles: layer, alt: alt, weather: full))
        #expect(abs(fromField[0] - 0.5) < 1e-9)  // classe 150 : f = 0,5
        #expect(abs(fromField[3] - 0.45) < 1e-9)  // classe 450 : 0,5 × 0,9
        #expect(fromField[0] == fromBBox[0] && fromField[3] == fromBBox[3])
        #expect(fromField[1].isNaN)
        // le champ ne décrit que son jour : J+1 transparent tant qu'il n'est pas demandé
        let otherDay = colorizer.values(Self.request(mode: .score, date: "2026-10-31", tiles: layer, alt: alt, weather: compact))
        #expect(otherDay.allSatisfy { $0.isNaN })
        // groupe : aereus 1,0 × 0,2 contre edulis 0,5 × 0,9 au pixel 3
        let aereus = TileColorizer.SpeciesTile(species: "boletus_aereus", png: Self.tile([(3, 254, 255)]))
        let group = colorizer.values(Self.request(mode: .score, date: "2026-10-30", tiles: layer + [aereus], alt: alt, weather: compact))
        #expect(abs(group[3] - 0.45) < 1e-9)
    }

    @Test("Pixel à plus de 7,5 km de toute cellule : transparent, jamais la météo d'une cellule lointaine")
    func farFromCells() throws {
        let colorizer = TileColorizer(palette: try Self.palette())
        let weather = try Self.weather()
        let tile = Self.tile([(0, 254, 255)])
        let layer = [TileColorizer.SpeciesTile(species: "boletus_edulis", png: tile)]
        // Tuile 6/33/22 : son coin haut gauche (5,6 E, 48,9 N) est à 200 km de c_1, et ses blocs de
        // 16 px font 24 km : aucun centre de bloc n'est à moins de 7,5 km de la seule cellule
        let far = TileColorizer.Request(z: 6, x: 33, y: 22, mode: .score, date: "2026-10-30", tiles: layer, alt: nil, weather: weather)
        #expect(colorizer.values(far).allSatisfy { $0.isNaN })
        #expect(TileColorizer.blockCells(z: 6, x: 33, y: 22, weather: weather).allSatisfy { $0 == nil })
        // Zoom 9 (blocs de 3 km) : le bloc qui contient la cellule la trouve, le coin de la tuile (50 km) non
        let p = TileMath.tile(lon: 8.4, lat: 47.0, z: 9)
        let cells = TileColorizer.blockCells(z: 9, x: p.x, y: p.y, weather: weather)
        #expect(cells.count == 256)
        #expect(cells[0] == nil)
        #expect(cells[(p.py / TileColorizer.weatherBlock) * 16 + p.px / TileColorizer.weatherBlock]?.info.id == "c_1")
        let i = p.py * Self.size + p.px
        let request = TileColorizer.Request(
            z: 9, x: p.x, y: p.y, mode: .score, date: "2026-10-30", tiles: [.init(species: "boletus_edulis", png: Self.tile([(i, 254, 255), (0, 254, 255)]))],
            alt: nil, weather: weather
        )
        let values = colorizer.values(request)
        #expect(abs(values[i] - 0.9) < 1e-9)
        #expect(values[0].isNaN)
        // Mode terrain : la distance aux cellules ne compte pas
        #expect(colorizer.values(TileColorizer.Request(z: 6, x: 33, y: 22, mode: .terrain, date: nil, tiles: layer, alt: nil, weather: WeatherField()))[0] == 1.0)
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
