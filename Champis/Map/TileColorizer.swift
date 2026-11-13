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
/// Même fonction de couleur dans les deux modes (échelle linéaire, 6 nov. 2026) : le violet de
/// `palette.scale`, dont l'alpha est la valeur du pixel (`Palette.Scale.alpha8`) ; l'overlay est
/// dessiné à l'opacité 1. Sans `scale` (API ancienne), couleur de la classe du pixel.
///
/// - Mode terrain : valeur = max sur les espèces de la couche de `T`.
/// - Mode score : valeur = max sur les espèces de `T × M_eff × Φ`, avec `M_eff × Φ` interpolé en
///   bilinéaire entre les centres des cellules météo qui encadrent le pixel (spec › Scoring ›
///   Interpolation de la météo entre cellules, 13 nov. 2026 ; poids calculés par bloc de pixels,
///   `blockSize`), chaque cellule pour la classe d'altitude lue par pixel dans la couche A (repli :
///   altitude médiane de la cellule). `/weather/bbox` et `/weather/field` alimentent le même
///   `WeatherField`.
/// - Pixel hors forêt, nodata, ou dont la cellule n'a pas de météo ni de ligne pour ce jour :
///   transparent, jamais un 0,5 inventé, jamais la seule météo de la voisine. Hors grille, cellule
///   la plus proche à moins de 7,5 km, sans interpolation.
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
    /// Bloc de pixels qui partage les mêmes poids d'interpolation : 16 px à partir du zoom 12
    /// (≈ 430 m à 47° N, un douzième de cellule : le dégradé entre deux centres ne fait pas de
    /// marche visible), moitié moins à chaque niveau en dessous, jamais moins de 2 px. Même règle
    /// que la carte web (`Field.blockPx`).
    static let maxBlock = 16
    static let fullBlockZoom = 12

    static func blockSize(z: Int) -> Int {
        if z >= fullBlockZoom { return maxBlock }
        return max(2, maxBlock >> (fullBlockZoom - z))
    }

    /// Échantillons d'interpolation d'une tuile, un par bloc (ligne par ligne) : les cellules
    /// météo qui y participent, rangées une fois dans `cells`, et pour chaque bloc l'indice de la
    /// cellule qui le porte (`home`, −1 sans météo), les indices de ses quatre coins (−1 si la
    /// cellule n'est pas chargée) et leurs poids bilinéaires.
    nonisolated struct BlockSamples: Sendable {
        let block: Int
        let blocks: Int
        let cells: [WeatherField.Cell]
        let home: [Int]
        let corners: [Int]
        let weights: [Double]

        static let empty = BlockSamples(block: TileColorizer.maxBlock, blocks: 0, cells: [], home: [], corners: [], weights: [])
    }

    let palette: Palette
    private let thresholds: [(min: Double, color: RGBA)]
    /// Violet de l'échelle, parsé une fois pour la tuile (65 536 pixels), et sa règle d'alpha.
    private let scale: (rgb: RGBA, rule: Palette.Scale)?

    init(palette: Palette) {
        self.palette = palette
        self.thresholds = palette.thresholds.map { (min: $0.min, color: RGBA(hex: $0.hex) ?? .clear) }
        if let rule = palette.scale, let rgb = rule.rgb {
            self.scale = (rgb: RGBA(r: rgb.r, g: rgb.g, b: rgb.b, a: 255), rule: rule)
        } else {
            self.scale = nil
        }
    }

    /// Couleur d'une valeur : le violet de l'échelle avec l'alpha de la valeur (même résultat que
    /// `Palette.pixelColor`, validé par les vecteurs). Sans échelle, premier seuil (ordre du fichier)
    /// dont `min ≤ value`, sinon le dernier, comme `Palette.classify`.
    func color(for value: Double) -> RGBA {
        if let scale {
            return RGBA(r: scale.rgb.r, g: scale.rgb.g, b: scale.rgb.b, a: scale.rule.alpha8(for: value))
        }
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

    /// Indice d'altitude du pixel `i` de la tuile d'altitude ; `nil` si inconnu (alpha 0 ou nodata).
    /// Indice de classe de 300 m (couche A) ou, quand la palette porte l'encodage de la couche E,
    /// indice de tranche de 20 m (`TileStore` convertit alors les tuiles A).
    func altitudeClass(_ png: DecodedPNG, at i: Int) -> Int? {
        let c = png.channels
        if (c == 2 || c == 4) && png.data[i * c + c - 1] == 0 { return nil }
        let k = Int(png.data[i * c])
        return k == (palette.elevEncoding?.nodata ?? palette.altEncoding.nodata) ? nil : k
    }

    /// `M_eff × Φ` pour une cellule, une espèce, un jour et l'indice de classe du pixel ; `nil` si
    /// l'API ne l'a pas (classe absente, jour hors des 11, espèce non demandée).
    func factor(cell: WeatherField.Cell, species: String, date: String, classIndex k: Int?) -> Double? {
        cell.factor(species: species, date: date, index: k, palette: palette)
    }

    /// Indices d'altitude mémoïsés par cellule : tout l'octet, pour couvrir les 254 tranches de
    /// 20 m de la couche E comme les classes de 300 m de la couche A.
    static let memoClasses = 256

    /// Échantillon d'interpolation de chaque bloc de la tuile, pris au centre du bloc : un calcul
    /// par bloc, partagé par toutes les espèces de la couche.
    static func blockSamples(z: Int, x: Int, y: Int, weather: WeatherField) -> BlockSamples {
        let block = blockSize(z: z)
        let blocks = size / block
        var cells: [WeatherField.Cell] = []
        var byGrid: [CellInterpolation.GridIndex: Int] = [:]
        var byID: [String: Int] = [:]
        var home = [Int](repeating: -1, count: blocks * blocks)
        var corners = [Int](repeating: -1, count: blocks * blocks * 4)
        var weights = [Double](repeating: 0, count: blocks * blocks * 4)

        /// Indice dans `cells` de la cellule de la grille, −1 si elle n'est pas chargée.
        func slot(_ g: CellInterpolation.GridIndex) -> Int {
            if let known = byGrid[g] { return known }
            var index = -1
            if let cell = weather.cell(at: g) {
                index = cells.count
                cells.append(cell)
                byID[cell.info.id] = index
            }
            byGrid[g] = index
            return index
        }

        for by in 0..<blocks {
            for bx in 0..<blocks {
                let p = TileMath.lonLat(
                    z: z, x: x, y: y,
                    px: (Double(bx) + 0.5) * Double(block),
                    py: (Double(by) + 0.5) * Double(block)
                )
                let b = by * blocks + bx
                let c = CellInterpolation.corners(lat: p.lat, lon: p.lon)
                let h = slot(c.containing)
                if h >= 0 {
                    home[b] = h
                    for n in 0..<4 {
                        corners[b * 4 + n] = slot(c.cells[n])
                        weights[b * 4 + n] = c.weights[n]
                    }
                } else if !weather.isUnavailable(c.containing),
                          let near = weather.nearestCell(lat: p.lat, lon: p.lon) {
                    // hors grille : la cellule la plus proche à moins de 7,5 km, sans interpolation
                    let index: Int
                    if let known = byID[near.info.id] {
                        index = known
                    } else {
                        index = cells.count
                        cells.append(near)
                        byID[near.info.id] = index
                    }
                    home[b] = index
                    corners[b * 4] = index
                    weights[b * 4] = 1
                }
            }
        }
        return BlockSamples(block: block, blocks: blocks, cells: cells, home: home, corners: corners, weights: weights)
    }

    /// Valeur affichée de chaque pixel (`nan` = transparent).
    func values(_ req: Request) -> [Double] {
        let n = Self.size * Self.size
        var out = [Double](repeating: .nan, count: n)
        let useWeather = req.mode == .score
        guard !useWeather || req.date != nil else { return out }
        let date = req.date ?? ""
        let alt: DecodedPNG? = req.alt.flatMap { a in
            a.width == Self.size && a.height == Self.size && a.data.count >= n * a.channels ? a : nil
        }

        // Poids d'interpolation par bloc, une fois pour toutes les espèces de la couche.
        let samples = useWeather
            ? Self.blockSamples(z: req.z, x: req.x, y: req.y, weather: req.weather)
            : BlockSamples.empty
        // Facteur d'une cellule mémoïsé par classe d'altitude : tableau plat, pas de dictionnaire
        // par pixel. `nan` = pas encore calculé ; −1 = pas de météo.
        let memoStride = Self.memoClasses + 1
        var memo = [Double](repeating: .nan, count: samples.cells.count * memoStride)

        /// `M_eff × Φ` de la cellule `ci` pour l'espèce et la classe `k` ; −1 si l'API ne l'a pas.
        func cellFactor(_ ci: Int, species: String, classIndex k: Int?) -> Double {
            let cell = samples.cells[ci]
            if let k, k >= Self.memoClasses {
                return factor(cell: cell, species: species, date: date, classIndex: k) ?? -1
            }
            let slot = ci * memoStride + (k.map { $0 + 1 } ?? 0)
            if memo[slot].isNaN {
                memo[slot] = factor(cell: cell, species: species, date: date, classIndex: k) ?? -1
            }
            return memo[slot]
        }

        for tile in req.tiles {
            let png = tile.png
            guard png.width == Self.size, png.height == Self.size, png.channels >= 1,
                  png.data.count >= n * png.channels
            else { continue }
            if useWeather {
                for i in memo.indices { memo[i] = .nan }
            }

            for i in 0..<n {
                guard var v = terrain(png, at: i) else { continue }
                if useWeather {
                    let px = i % Self.size
                    let py = i / Self.size
                    let b = (py / samples.block) * samples.blocks + px / samples.block
                    let h = samples.home[b]
                    if h < 0 { continue }
                    let k = alt.flatMap { altitudeClass($0, at: i) }
                    // la cellule qui porte le pixel doit avoir une valeur : jamais la seule voisine
                    let base = cellFactor(h, species: tile.species, classIndex: k)
                    if base < 0 { continue }
                    var num = 0.0
                    var den = 0.0
                    for c in 0..<4 {
                        let ci = samples.corners[b * 4 + c]
                        if ci < 0 { continue }
                        let f = ci == h ? base : cellFactor(ci, species: tile.species, classIndex: k)
                        if f < 0 { continue }
                        let w = samples.weights[b * 4 + c]
                        num += w * f
                        den += w
                    }
                    v *= den > 0 ? num / den : base
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
