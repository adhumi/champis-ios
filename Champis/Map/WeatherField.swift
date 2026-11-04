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
/// du MainActor. Même logique que la carte web (`weatherRow`, `altCenter`, `nearestCell`), avec un
/// index spatial (`CellIndex`) pour la cellule la plus proche.
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

    private(set) var today: String?
    private(set) var cells: [String: Cell] = [:]
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
    }

    /// Cellule la plus proche à moins de `CellIndex.maxDistanceKm` (7,5 km) ; `nil` au-delà ou
    /// sans météo : le pixel reste transparent.
    func nearestCell(lat: Double, lon: Double) -> Cell? {
        guard let entry = index.nearest(lat: lat, lon: lon) else { return nil }
        return cells[entry.id]
    }
}
