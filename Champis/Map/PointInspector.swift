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
        /// `M_eff × Φ` appliqué (mode score), interpolé entre les cellules météo voisines ; `nil` en
        /// mode terrain.
        let factor: Double?
        /// `T` (mode terrain) ou `S = T × M_eff × Φ` (mode score).
        let value: Double
        /// Ligne complète (`M`, `M_eff`, `Φ`) quand la météo vient de `/weather/bbox` ; `nil` sous le
        /// champ compact, la fiche la prend alors de `GET /weather?cell=` (`MapModel.pointRow`).
        /// C'est la ligne de `cell`, la cellule qui porte le point : son `M_eff × Φ` diffère de
        /// `factor` quand celui-ci est interpolé.
        let row: WeatherRow?
        /// Cellule météo qui porte le point (ses facteurs expliquent le score).
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
        /// Indice lu dans la tuile d'altitude, tel que le coloriste l'emploie : classe de 300 m, ou
        /// tranche de 20 m quand la palette porte l'encodage de la couche E.
        var altIndex: Int? = nil
        /// Altitude du pixel (m) lue dans la couche E ; `nil` avec la seule couche A.
        var altitudeM: Double? = nil
        /// `factor` mêle la météo de cellules voisines (spec › Scoring › Interpolation, 13 nov. 2026).
        var interpolated = false
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
    var date: String?
    let outcome: Outcome

    // Toutes les espèces du point (spec › App iOS › Fiche d'un point, 17 nov. 2026) : `outcome` ne
    // parle que de la couche affichée, ce qui suit vaut pour tout le catalogue.

    /// `T` du pixel pour chaque espèce du catalogue qui a du terrain ici (`T > 0`).
    var terrains: [String: Double] = [:]
    /// Valeur de chaque espèce de la couche telle que la carte la montre : `T` en mode terrain,
    /// `S` interpolé entre cellules en mode score (absente sans météo).
    var layerValues: [String: Double] = [:]
    /// Cellule météo qui porte le point (mode score) ; `GET /weather?cell=` donne les autres espèces.
    var cell: WeatherCellInfo? = nil
    var stale = false
    /// Indice `k` de la classe de 300 m du pixel, `nil` si inconnu.
    var altClass: Int? = nil
    /// Classe utilisée pour la météo (`"450"`), `nil` en mode terrain ou sans cellule.
    var altKey: String? = nil
    /// La classe vient de l'altitude médiane de la cellule, pas du pixel.
    var altFallback = false
    /// Indice lu dans la tuile d'altitude, tel que le coloriste l'emploie.
    var altIndex: Int? = nil
    /// Altitude du pixel (m) lue dans la couche E ; `nil` avec la seule couche A.
    var altitudeM: Double? = nil

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
    /// meilleure (règle 9), comme la fiche de la carte web. `catalogSpecies` : les autres espèces
    /// dont la fiche liste le terrain (17 nov. 2026) ; une tuile qui ne se lit pas pour l'une d'elles
    /// l'écarte de la liste sans faire échouer la fiche.
    static func inspect(
        latitude: Double, longitude: Double, settings: RenderSettings, store: TileStore, catalogSpecies: [String] = []
    ) async throws -> PointInfo {
        let base = { (outcome: PointInfo.Outcome) in
            PointInfo(latitude: latitude, longitude: longitude, mode: settings.mode, date: settings.date, outcome: outcome)
        }
        // sans couche (fiche d'un coin ouverte depuis Mes coins, 18 nov. 2026) : seulement le
        // terrain des espèces du catalogue, aucune n'est en exergue
        let members = settings.layer?.members ?? []
        guard let colorizer = settings.colorizer, !members.isEmpty || !catalogSpecies.isEmpty else { return base(.noData) }
        let size = TileMath.tileSize
        let t = TileMath.tile(lon: longitude, lat: latitude, z: zoom)
        let i = t.py * size + t.px

        // Indice tel que le coloriste le lit ; avec la couche E, c'est une tranche de 20 m dont on
        // tire l'altitude du pixel et sa classe de 300 m (pour la fiche et la ligne météo).
        let palette = colorizer.palette
        var altIndex: Int?
        if let alt = try await store.altitudeTile(z: zoom, x: t.x, y: t.y, palette: palette),
           alt.width == size, alt.height == size, alt.data.count >= size * size * alt.channels {
            altIndex = colorizer.altitudeClass(alt, at: i)
        }
        var altClass = altIndex
        var altitudeM: Double?
        if let elev = palette.elevEncoding, let k = altIndex {
            let altitude = CellInterpolation.elevation(index: k, stepM: elev.stepM)
            altitudeM = altitude
            altClass = Int((altitude / palette.altEncoding.classM).rounded(.down))
        }
        let useWeather = settings.mode == .score
        // Même météo que la couleur de la carte : interpolée entre les centres des cellules voisines.
        let sample = useWeather ? settings.weather.sample(lat: latitude, lon: longitude) : nil

        var best: PointInfo.Scored?
        var sawTerrain = false
        var terrains: [String: Double] = [:]
        var layerValues: [String: Double] = [:]
        for sid in members {
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
                // `factor` vient de `/weather/bbox` ou du champ compact `/weather/field` (sous le zoom 9) ;
                // la ligne complète n'existe que pour le premier, la fiche charge le reste par `GET /weather`.
                guard let sample, let date = settings.date,
                      let alt = sample.home.altKey(classIndex: altClass, encoding: palette.altEncoding),
                      let factor = sample.factor(species: sid, date: date, index: altIndex, palette: palette)
                else { continue }
                let cell = sample.home
                candidate = PointInfo.Scored(
                    species: sid, terrain: terrain, factor: factor, value: terrain * factor,
                    row: cell.row(species: sid, date: date, altKey: alt.key),
                    cell: cell.info, stale: cell.stale, altClass: altClass, altKey: alt.key, altFallback: alt.fallback
                )
                candidate.interpolated = sample.isInterpolated
                candidate.altIndex = altIndex
                candidate.altitudeM = altitudeM
            }
            layerValues[sid] = candidate.value
            if let current = best, candidate.value <= current.value { continue }
            best = candidate
        }
        var info: PointInfo
        if var best {
            best.terrains = terrains
            info = base(.scored(best))
        } else {
            info = base(sawTerrain && useWeather ? .noWeather : .noData)
        }
        let others = await otherTerrains(
            catalogSpecies.filter { !members.contains($0) }, z: zoom, x: t.x, y: t.y, pixel: i, colorizer: colorizer,
            store: store
        )
        info.terrains = terrains.merging(others) { layer, _ in layer }.filter { $0.value > 0 }
        info.layerValues = layerValues
        info.altClass = altClass
        info.altIndex = altIndex
        info.altitudeM = altitudeM
        if let home = sample?.home {
            info.cell = home.info
            info.stale = home.stale
            if let alt = home.altKey(classIndex: altClass, encoding: palette.altEncoding) {
                info.altKey = alt.key
                info.altFallback = alt.fallback
            }
        }
        return info
    }

    /// `T` du pixel pour des espèces hors de la couche, lues en parallèle (une tuile `G` porte tout
    /// un groupe : une lecture par famille). Une tuile absente ou illisible ne donne rien.
    private static func otherTerrains(
        _ species: [String], z: Int, x: Int, y: Int, pixel: Int, colorizer: TileColorizer, store: TileStore
    ) async -> [String: Double] {
        let size = TileMath.tileSize
        return await withTaskGroup(of: (String, Double?).self) { group in
            for sid in species {
                group.addTask {
                    guard let png = try? await store.terrainTile(species: sid, z: z, x: x, y: y),
                          png.width == size, png.height == size, png.data.count >= size * size * png.channels
                    else { return (sid, nil) }
                    return (sid, colorizer.terrain(png, at: pixel))
                }
            }
            var out: [String: Double] = [:]
            for await (sid, terrain) in group {
                if let terrain {
                    out[sid] = terrain
                }
            }
            return out
        }
    }
}
