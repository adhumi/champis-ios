import ChampisPMTiles
import ChampisScoring
import Foundation

/// Ce que la fiche au toucher sait d'un point (v1 réduite, décision du 30 oct. 2026) : l'espèce
/// qui porte le score, `T`, `M_eff`, `Φ`, la cellule météo et la classe d'altitude. Les facteurs
/// terrain (essence, pH, exposition) ne sont pas dans les tuiles : pas de fiche terrain détaillée.
nonisolated struct PointInfo: Identifiable, Sendable {
    nonisolated struct Scored: Sendable {
        let species: String
        /// Potentiel terrain du pixel, dans [0, 1].
        let terrain: Double
        /// `M_eff × Φ` appliqué (mode score) ; `nil` en mode terrain.
        let factor: Double?
        /// `T` (mode terrain) ou `S = T × M_eff × Φ` (mode score).
        let value: Double
        let row: WeatherRow?
        let cell: WeatherCellInfo?
        let stale: Bool
        /// Indice `k` lu dans la couche A (`[300k, 300k + 300[` m), `nil` si inconnu.
        let altClass: Int?
        /// Classe utilisée pour la météo (`"450"`), `nil` en mode terrain.
        let altKey: String?
        /// La classe vient de l'altitude médiane de la cellule, pas du pixel.
        let altFallback: Bool
        /// `T` du pixel pour chaque espèce de la couche (pour un coin : le backend n'a que la météo).
        var terrains: [String: Double] = [:]
    }

    nonisolated enum Outcome: Sendable {
        /// Hors forêt, hors emprise ou nodata pour toutes les espèces de la couche.
        case noData
        /// Du terrain, mais aucune ligne météo pour ce point et ce jour.
        case noWeather
        case scored(Scored)
    }

    let id = UUID()
    let latitude: Double
    let longitude: Double
    let mode: MapMode
    let date: String?
    let outcome: Outcome

    var scored: Scored? {
        if case .scored(let s) = outcome { return s }
        return nil
    }

    var isNoData: Bool {
        if case .noData = outcome { return true }
        return false
    }

    var isNoWeather: Bool {
        if case .noWeather = outcome { return true }
        return false
    }
}

nonisolated enum PointInspector {
    /// Niveau le plus fin des tuiles : un pixel y fait ~25 m sur la France.
    static let zoom = 15

    /// Lit `T` (et `A`) au pixel de la coordonnée pour chaque espèce de la couche et garde la
    /// meilleure (règle 9), comme la fiche de la carte web.
    static func inspect(
        latitude: Double, longitude: Double, settings: RenderSettings, store: TileStore
    ) async throws -> PointInfo {
        let base = { (outcome: PointInfo.Outcome) in
            PointInfo(latitude: latitude, longitude: longitude, mode: settings.mode, date: settings.date, outcome: outcome)
        }
        guard let layer = settings.layer, let colorizer = settings.colorizer else { return base(.noData) }
        let size = TileMath.tileSize
        let t = TileMath.tile(lon: longitude, lat: latitude, z: zoom)
        let i = t.py * size + t.px

        var altClass: Int?
        if let alt = try await store.altitudeTile(z: zoom, x: t.x, y: t.y),
           alt.width == size, alt.height == size, alt.data.count >= size * size * alt.channels {
            altClass = colorizer.altitudeClass(alt, at: i)
        }
        let useWeather = settings.mode == .score
        let cell = useWeather ? settings.weather.nearestCell(lat: latitude, lon: longitude) : nil

        var best: PointInfo.Scored?
        var sawTerrain = false
        var terrains: [String: Double] = [:]
        for sid in layer.members {
            guard let png = try await store.terrainTile(species: sid, z: zoom, x: t.x, y: t.y),
                  png.width == size, png.height == size, png.data.count >= size * size * png.channels,
                  let terrain = colorizer.terrain(png, at: i)
            else { continue }
            sawTerrain = true
            terrains[sid] = terrain
            var candidate = PointInfo.Scored(
                species: sid, terrain: terrain, factor: nil, value: terrain, row: nil, cell: nil, stale: false,
                altClass: altClass, altKey: nil, altFallback: false
            )
            if useWeather {
                guard let cell, let date = settings.date,
                      let alt = cell.altKey(classIndex: altClass, encoding: colorizer.palette.altEncoding),
                      let row = cell.row(species: sid, date: date, altKey: alt.key)
                else { continue }
                candidate = PointInfo.Scored(
                    species: sid, terrain: terrain, factor: row.factor, value: terrain * row.factor, row: row,
                    cell: cell.info, stale: cell.stale, altClass: altClass, altKey: alt.key, altFallback: alt.fallback
                )
            }
            if let current = best, candidate.value <= current.value { continue }
            best = candidate
        }
        if var best {
            best.terrains = terrains
            return base(.scored(best))
        }
        return base(sawTerrain && useWeather ? .noWeather : .noData)
    }
}
