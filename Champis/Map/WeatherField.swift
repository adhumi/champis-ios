import ChampisScoring
import Foundation

/// Météo reçue de `GET /weather/bbox`, fusionnée emprise après emprise : par cellule, par espèce,
/// par jour et par classe d'altitude. Valeur pure et `Sendable`, lue par le coloriste hors du
/// MainActor. Même logique que la carte web (`weatherRow`, `altCenter`, `nearestCell`).
nonisolated struct WeatherField: Sendable {
    nonisolated struct Cell: Sendable {
        let info: WeatherCellInfo
        var stale: Bool
        /// espèce → jour ISO → clé de classe (`"150"`) → ligne.
        var rows: [String: [String: [String: WeatherRow]]]

        func row(species: String, date: String, altKey: String) -> WeatherRow? {
            rows[species]?[date]?[altKey]
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
    private(set) var unavailable: Set<String> = []
    private(set) var retryAfter: Int?

    init() {}

    var isEmpty: Bool { cells.isEmpty }
    var anyStale: Bool { cells.values.contains { $0.stale } }

    /// Fusionne une réponse : les cellules déjà connues gardent leurs autres espèces et jours. Un
    /// changement de `today` (minuit passé côté API) vide tout : les dates ne se recouvrent plus.
    mutating func merge(_ response: WeatherBBoxResponse) {
        if today != response.today {
            cells = [:]
            today = response.today
        }
        for c in response.cells {
            var cell = cells[c.cell.id] ?? Cell(info: c.cell, stale: false, rows: [:])
            cell.stale = c.stale
            for (sid, days) in c.species {
                var byDate = cell.rows[sid] ?? [:]
                for day in days {
                    byDate[day.date] = day.byAlt
                }
                cell.rows[sid] = byDate
            }
            cells[c.cell.id] = cell
        }
        unavailable = Set(response.unavailable)
        retryAfter = response.retryAfter
    }

    /// Cellule la plus proche (distance équirectangulaire, comme la carte web) ; `nil` sans météo.
    func nearestCell(lat: Double, lon: Double) -> Cell? {
        let k = cos(lat * .pi / 180)
        var best: Cell?
        var bestDistance = Double.infinity
        for cell in cells.values {
            let dLat = cell.info.lat - lat
            let dLon = (cell.info.lon - lon) * k
            let d = dLat * dLat + dLon * dLon
            if d < bestDistance {
                bestDistance = d
                best = cell
            }
        }
        return best
    }
}
