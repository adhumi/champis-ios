import ChampisScoring
import Foundation

/// `M_eff × Φ` d'une cellule pour une espèce, un jour et une classe d'altitude : ce que la carte
/// applique à `T`. Deux sources l'alimentent sous la même forme : `GET /weather/bbox` (ligne
/// complète, `row` connue) et `GET /weather/field` (le produit seul, `row` nil : `M_eff` et `Φ`
/// séparés passent par `GET /weather?cell=`).
nonisolated struct WeatherFactor: Hashable, Sendable {
    let value: Double
    let row: WeatherRow?
}

/// Météo reçue de `GET /weather/bbox` (11 jours, emprise bornée) et de `GET /weather/field` (un
/// jour, sans plafond), fusionnée emprise après emprise et jour après jour : par cellule, par
/// espèce, par jour et par classe d'altitude. Valeur pure et `Sendable`, lue par le coloriste hors
/// du MainActor. Même logique que la carte web (`field.js`) : la météo d'un point est interpolée
/// entre les centres des cellules qui l'encadrent (`sample`, spec › Scoring › Interpolation de la
/// météo entre cellules, 13 nov. 2026) ; hors grille, un index spatial (`CellIndex`) donne la
/// cellule la plus proche.
nonisolated struct WeatherField: Sendable {
    nonisolated struct Cell: Sendable {
        let info: WeatherCellInfo
        var stale: Bool
        /// espèce → jour ISO → clé de classe (`"150"`) → facteur.
        var factors: [String: [String: [String: WeatherFactor]]]

        init(info: WeatherCellInfo, stale: Bool, factors: [String: [String: [String: WeatherFactor]]] = [:]) {
            self.info = info
            self.stale = stale
            self.factors = factors
        }

        /// `M_eff × Φ`, quelle que soit la source ; `nil` si l'API ne l'a pas donné.
        func factor(species: String, date: String, altKey: String) -> Double? {
            factors[species]?[date]?[altKey]?.value
        }

        /// Ligne complète (`M`, `M_eff`, `Φ`), connue seulement par `/weather/bbox`.
        func row(species: String, date: String, altKey: String) -> WeatherRow? {
            factors[species]?[date]?[altKey]?.row
        }

        /// Clé `by_alt` à utiliser pour un pixel : la classe lue dans la couche A (indice `k`) ; sans
        /// couche A ou classe inconnue, celle de l'altitude médiane de la forêt de la cellule
        /// (`fallback`, la fiche dit « médiane cellule »). `nil` quand rien n'est connu : le pixel reste
        /// transparent, jamais une valeur inventée.
        func altKey(classIndex k: Int?, encoding: Palette.AltEncoding) -> (key: String, fallback: Bool)? {
            let altitude: Double
            let fallback: Bool
            if let k, k != encoding.nodata {
                altitude = (Double(k) + 0.5) * encoding.classM
                fallback = false
            } else if let elevation = info.elevationM {
                altitude = elevation
                fallback = true
            } else {
                return nil
            }
            guard let first = info.altClasses.first else { return nil }
            let target = (altitude / encoding.classM).rounded(.down) * encoding.classM + encoding.classM / 2
            var best = first
            for center in info.altClasses.dropFirst() where abs(center - target) < abs(best - target) {
                best = center
            }
            return (Self.key(forCenter: best), fallback)
        }

        /// `str(int(alt))` côté API : `150.0` → `"150"`.
        static func key(forCenter center: Double) -> String {
            String(Int(center))
        }
    }

    /// Ce qu'il faut pour interpoler la météo en un point : la cellule qui porte le point, les
    /// cellules chargées des quatre coins (SO, SE, NO, NE ; `nil` si absente) et leurs poids
    /// bilinéaires. Hors grille, `corners` est vide : la cellule la plus proche, sans interpolation.
    nonisolated struct Sample: Sendable {
        let home: Cell
        let corners: [Cell?]
        let weights: [Double]

        /// Au moins une autre cellule que `home` participe à la valeur.
        var isInterpolated: Bool {
            corners.contains { $0 != nil && $0?.info.id != home.info.id }
        }

        /// Valeur interpolée : moyenne des coins qui en ont une, poids renormalisés ; `nil` si la
        /// cellule qui porte le point n'en a pas (jamais la météo de la voisine).
        func value(_ get: (Cell) -> Double?) -> Double? {
            guard let base = get(home) else { return nil }
            var num = 0.0
            var den = 0.0
            for (cell, weight) in zip(corners, weights) {
                guard let cell, let v = get(cell) else { continue }
                num += weight * v
                den += weight
            }
            return den > 0 ? num / den : base
        }

        /// `M_eff × Φ` interpolé pour une espèce, un jour et l'indice de classe d'altitude du
        /// pixel : chaque cellule donne sa valeur pour sa classe la plus proche.
        func factor(species: String, date: String, classIndex k: Int?, encoding: Palette.AltEncoding) -> Double? {
            value { cell in
                guard let alt = cell.altKey(classIndex: k, encoding: encoding) else { return nil }
                return cell.factor(species: species, date: date, altKey: alt.key)
            }
        }
    }

    private(set) var today: String?
    private(set) var cells: [String: Cell] = [:]
    /// Grille Lambert-93 de 5 km : indices → identifiant de la cellule chargée.
    private(set) var grid: [CellInterpolation.GridIndex: String] = [:]
    /// Cellules de la grille que l'API a listées sans météo : leurs pixels restent transparents.
    private(set) var unavailableGrid: Set<CellInterpolation.GridIndex> = []
    /// Cellules sans météo listées par `/weather/bbox` ; `/weather/field` ne donne qu'un nombre.
    private(set) var unavailable: Set<String> = []
    private(set) var retryAfter: Int?
    private(set) var index = CellIndex()

    init() {}

    var isEmpty: Bool { cells.isEmpty }
    var anyStale: Bool { cells.values.contains { $0.stale } }

    /// Fusionne une réponse de `/weather/bbox` : les cellules déjà connues gardent leurs autres
    /// espèces et jours. Un changement de `today` (minuit passé côté API) vide tout : les dates ne
    /// se recouvrent plus.
    mutating func merge(_ response: WeatherBBoxResponse) {
        resetIfNewDay(response.today)
        for c in response.cells {
            var cell = cells[c.cell.id] ?? Cell(info: c.cell, stale: false)
            cell.stale = c.stale
            for (sid, days) in c.species {
                var byDate = cell.factors[sid] ?? [:]
                for day in days {
                    var byAlt = byDate[day.date] ?? [:]
                    for (altKey, row) in day.byAlt {
                        byAlt[altKey] = WeatherFactor(value: row.factor, row: row)
                    }
                    byDate[day.date] = byAlt
                }
                cell.factors[sid] = byDate
            }
            cells[c.cell.id] = cell
        }
        unavailable = Set(response.unavailable)
        retryAfter = response.retryAfter
        rebuildIndex()
    }

    /// Fusionne un champ compact de `/weather/field` : le jour `day` de chaque cellule, par espèce
    /// et classe, avec `M_eff = f` et `Φ = 1` pour ce que la carte en fait (`value = f`). Une ligne
    /// complète déjà connue par `/weather/bbox` pour le même facteur est gardée ; sinon `row` est
    /// nil et la fiche passe par `GET /weather?cell=`.
    mutating func merge(_ field: WeatherFieldResponse) {
        resetIfNewDay(field.today)
        for c in field.cells {
            var cell = cells[c.id] ?? Cell(info: c.info, stale: false)
            cell.stale = c.stale
            for (sid, byAlt) in c.f {
                var byDate = cell.factors[sid] ?? [:]
                var existing = byDate[field.day] ?? [:]
                for (altKey, f) in byAlt {
                    var row: WeatherRow?
                    if let known = existing[altKey]?.row, abs(known.factor - f) < 1e-9 {
                        row = known
                    }
                    existing[altKey] = WeatherFactor(value: f, row: row)
                }
                byDate[field.day] = existing
                cell.factors[sid] = byDate
            }
            cells[c.id] = cell
        }
        rebuildIndex()
    }

    private mutating func resetIfNewDay(_ newToday: String) {
        if today != newToday {
            cells = [:]
            unavailable = []
            retryAfter = nil
            today = newToday
        }
    }

    private mutating func rebuildIndex() {
        index = CellIndex(cells.values.map { CellIndex.Entry(id: $0.info.id, lat: $0.info.lat, lon: $0.info.lon) })
        var grid: [CellInterpolation.GridIndex: String] = [:]
        grid.reserveCapacity(cells.count)
        for id in cells.keys {
            if let g = CellInterpolation.GridIndex(id: id) {
                grid[g] = id
            }
        }
        self.grid = grid
        unavailableGrid = Set(
            unavailable.compactMap { CellInterpolation.GridIndex(id: $0) }.filter { grid[$0] == nil }
        )
    }

    /// Cellule chargée aux indices `g` de la grille.
    func cell(at g: CellInterpolation.GridIndex) -> Cell? {
        grid[g].flatMap { cells[$0] }
    }

    /// L'API a listé cette cellule sans météo (et aucune réponse ne l'a donnée depuis).
    func isUnavailable(_ g: CellInterpolation.GridIndex) -> Bool {
        unavailableGrid.contains(g)
    }

    /// Échantillon d'interpolation d'un point ; `nil` sans météo (cellule listée sans météo, ou
    /// hors grille à plus de 7,5 km de toute cellule).
    func sample(lat: Double, lon: Double) -> Sample? {
        let c = CellInterpolation.corners(lat: lat, lon: lon)
        if let home = cell(at: c.containing) {
            return Sample(home: home, corners: c.cells.map { cell(at: $0) }, weights: c.weights)
        }
        if isUnavailable(c.containing) { return nil }
        return nearestCell(lat: lat, lon: lon).map { Sample(home: $0, corners: [], weights: []) }
    }

    /// Cellule la plus proche à moins de `CellIndex.maxDistanceKm` (7,5 km) ; `nil` au-delà ou
    /// sans météo : le pixel reste transparent.
    func nearestCell(lat: Double, lon: Double) -> Cell? {
        guard let entry = index.nearest(lat: lat, lon: lon) else { return nil }
        return cells[entry.id]
    }
}
