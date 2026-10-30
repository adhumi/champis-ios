import ChampisPMTiles
import ChampisScoring
import Foundation

/// Mode d'affichage : potentiel terrain seul, ou score du jour. Même overlay, deux fonctions de couleur.
nonisolated enum MapMode: String, CaseIterable, Sendable {
    case terrain
    case score
}

nonisolated struct RGBA: Hashable, Sendable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8

    static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)

    init(r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// `#RRGGBB` ou `#RRGGBBAA`, comme `palette.json`.
    init?(hex: String) {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6 || digits.count == 8, let v = UInt32(digits, radix: 16) else { return nil }
        if digits.count == 8 {
            self.init(r: UInt8((v >> 24) & 0xFF), g: UInt8((v >> 16) & 0xFF), b: UInt8((v >> 8) & 0xFF), a: UInt8(v & 0xFF))
        } else {
            self.init(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF), a: 255)
        }
    }
}

/// Colorisation d'une tuile : fonction pure, testée sans MapKit (skill `swiftui-mapkit`).
///
/// - Mode terrain : valeur = max sur les espèces de la couche de `T`.
/// - Mode score : valeur = max sur les espèces de `T × M_eff × Φ`, avec `M_eff` et `Φ` de la cellule
///   météo la plus proche (par bloc de 16 × 16 px, une cellule fait 5 km) et de la classe d'altitude
///   lue par pixel dans la couche A (repli : altitude médiane de la cellule).
/// - Pixel hors forêt, nodata, sans cellule ou sans ligne météo : transparent. Jamais un 0,5 inventé.
nonisolated struct TileColorizer: Sendable {
    nonisolated struct SpeciesTile: Sendable {
        let species: String
        let png: DecodedPNG
    }

    nonisolated struct Request: Sendable {
        let z: Int
        let x: Int
        let y: Int
        let mode: MapMode
        /// Jour affiché (ISO) ; requis en mode score.
        let date: String?
        /// `T` de chaque espèce de la couche (celles dont la tuile existe).
        let tiles: [SpeciesTile]
        /// Couche A (classes d'altitude), si disponible.
        let alt: DecodedPNG?
        let weather: WeatherField
    }

    static let size = TileMath.tileSize
    static let weatherBlock = 16

    let palette: Palette
    private let thresholds: [(min: Double, color: RGBA)]

    init(palette: Palette) {
        self.palette = palette
        self.thresholds = palette.thresholds.map { (min: $0.min, color: RGBA(hex: $0.hex) ?? .clear) }
    }

    /// Couleur d'une valeur : premier seuil (ordre du fichier) dont `min ≤ value`, sinon le dernier,
    /// comme `Palette.classify`.
    func color(for value: Double) -> RGBA {
        for t in thresholds where value >= t.min {
            return t.color
        }
        return thresholds.last?.color ?? .clear
    }

    /// `T` ∈ [0, 1] du pixel `i` ; `nil` hors forêt (alpha 0) ou nodata (`tile_encoding`).
    func terrain(_ png: DecodedPNG, at i: Int) -> Double? {
        let c = png.channels
        if (c == 2 || c == 4) && png.data[i * c + c - 1] == 0 { return nil }
        let v = png.data[i * c]
        if Int(v) == palette.tileEncoding.nodata { return nil }
        return Double(v) / palette.tileEncoding.scale
    }

    /// Indice de classe d'altitude du pixel `i` de la couche A ; `nil` si inconnu (alpha 0 ou nodata).
    func altitudeClass(_ png: DecodedPNG, at i: Int) -> Int? {
        let c = png.channels
        if (c == 2 || c == 4) && png.data[i * c + c - 1] == 0 { return nil }
        let k = Int(png.data[i * c])
        return k == palette.altEncoding.nodata ? nil : k
    }

    /// `M_eff × Φ` pour une cellule, une espèce, un jour et l'indice de classe du pixel ; `nil` si
    /// l'API ne l'a pas (classe absente, jour hors des 11, espèce non demandée).
    func factor(cell: WeatherField.Cell, species: String, date: String, classIndex k: Int?) -> Double? {
        guard let alt = cell.altKey(classIndex: k, encoding: palette.altEncoding),
              let row = cell.row(species: species, date: date, altKey: alt.key)
        else { return nil }
        return row.factor
    }

    /// Valeur affichée de chaque pixel (`nan` = transparent).
    func values(_ req: Request) -> [Double] {
        let n = Self.size * Self.size
        var out = [Double](repeating: .nan, count: n)
        let useWeather = req.mode == .score
        guard !useWeather || req.date != nil else { return out }
        let date = req.date ?? ""
        let blocks = Self.size / Self.weatherBlock

        for tile in req.tiles {
            let png = tile.png
            guard png.width == Self.size, png.height == Self.size, png.channels >= 1,
                  png.data.count >= n * png.channels
            else { continue }
            let alt: DecodedPNG? = req.alt.flatMap { a in
                a.width == Self.size && a.height == Self.size && a.data.count >= n * a.channels ? a : nil
            }

            // Cellule météo par bloc, facteur mémoïsé par (bloc, classe d'altitude) ; −1 = pas de météo.
            var blockCells: [WeatherField.Cell?] = []
            var memo: [[Int: Double]] = []
            if useWeather {
                blockCells.reserveCapacity(blocks * blocks)
                for by in 0..<blocks {
                    for bx in 0..<blocks {
                        let p = TileMath.lonLat(
                            z: req.z, x: req.x, y: req.y,
                            px: (Double(bx) + 0.5) * Double(Self.weatherBlock),
                            py: (Double(by) + 0.5) * Double(Self.weatherBlock)
                        )
                        blockCells.append(req.weather.nearestCell(lat: p.lat, lon: p.lon))
                    }
                }
                memo = [[Int: Double]](repeating: [:], count: blocks * blocks)
            }

            for i in 0..<n {
                guard var v = terrain(png, at: i) else { continue }
                if useWeather {
                    let px = i % Self.size
                    let py = i / Self.size
                    let b = (py / Self.weatherBlock) * blocks + px / Self.weatherBlock
                    guard let cell = blockCells[b] else { continue }
                    let k = alt.flatMap { altitudeClass($0, at: i) }
                    let memoKey = k ?? -1
                    let f: Double
                    if let cached = memo[b][memoKey] {
                        f = cached
                    } else {
                        f = factor(cell: cell, species: tile.species, date: date, classIndex: k) ?? -1
                        memo[b][memoKey] = f
                    }
                    if f < 0 { continue }
                    v *= f
                }
                if out[i].isNaN || v > out[i] {
                    out[i] = v
                }
            }
        }
        return out
    }

    /// Pixels RGBA (256 × 256 × 4) de la tuile ; `nil` si aucune tuile d'espèce n'était disponible.
    func render(_ req: Request) -> [UInt8]? {
        guard !req.tiles.isEmpty else { return nil }
        let vals = values(req)
        var rgba = [UInt8](repeating: 0, count: vals.count * 4)
        for i in 0..<vals.count where !vals[i].isNaN {
            let c = color(for: vals[i])
            rgba[i * 4] = c.r
            rgba[i * 4 + 1] = c.g
            rgba[i * 4 + 2] = c.b
            rgba[i * 4 + 3] = c.a
        }
        return rgba
    }
}
