import Foundation

/// Indice par département de `GET /departements`, projeté sur la couche affichée : pour un groupe,
/// la série `groups[id]` (max des espèces, `leading`) ; pour une espèce, `species[id]`. Il ne sert
/// qu'au bandeau des jours (pastille = indice du département sous le centre de la carte) : la vue
/// France est retirée (spec › Points ouverts › Vue France et indice par département, 4 nov. 2026).
nonisolated struct DeptIndex: Sendable {
    let layerKey: LayerKey
    let today: String
    let computedAt: String
    /// code → jour ISO → ligne
    private let series: [String: [String: DeptDay]]

    init(response: DepartementsResponse, layer: Layer) {
        layerKey = layer.key
        today = response.today
        computedAt = response.computedAt
        var series: [String: [String: DeptDay]] = [:]
        for (code, entry) in response.departements {
            let rows: [DeptDay]?
            switch layer.key {
            case .group(let id): rows = entry.groups[id]
            case .species(let id): rows = entry.species[id]
            }
            guard let rows else { continue }
            var byDate: [String: DeptDay] = [:]
            for row in rows {
                byDate[row.date] = row
            }
            series[code] = byDate
        }
        self.series = series
    }

    var codes: [String] { Array(series.keys) }
    var isEmpty: Bool { series.isEmpty }

    func row(code: String, date: String) -> DeptDay? {
        series[code]?[date]
    }

    /// Valeur du jour ; `nil` sans indice (département hors grille, météo manquante) : transparent.
    func value(code: String, date: String) -> Double? {
        row(code: code, date: date)?.value
    }
}
