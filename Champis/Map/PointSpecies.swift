import ChampisScoring
import Foundation

/// Une espèce qui a du terrain au point touché (spec › App iOS › Fiche d'un point, toutes les
/// espèces et une phrase, 17 nov. 2026).
nonisolated struct PointSpecies: Identifiable, Hashable, Sendable {
    /// Identifiant de l'espèce.
    let id: String
    /// Potentiel terrain du pixel, dans ]0, 1].
    let terrain: Double
    /// `T` en mode terrain, `S` du jour en mode score ; `nil` sans météo pour l'espèce.
    let value: Double?
}

/// Les espèces d'une famille (groupe d'affichage du référentiel) présentes au point.
nonisolated struct PointFamily: Identifiable, Hashable, Sendable {
    /// Identifiant du groupe ; vide pour les espèces sans groupe.
    let id: String
    let title: String
    /// Par score décroissant, puis par nom français.
    let species: [PointSpecies]

    /// Meilleur score de la famille au point ; `nil` si aucune espèce n'en a.
    var best: Double? { species.compactMap(\.value).max() }
}

/// Liste des espèces du point, fonctions pures : rien n'est nommé ici, tout vient de `GET /species`.
nonisolated enum PointFamilies {
    /// Titre de la section des espèces sans groupe dans le référentiel.
    static let ungroupedTitle = "Autres espèces"

    /// Valeur de chaque espèce qui a du terrain au point. Une espèce de la couche garde la valeur
    /// de la carte (interpolée entre cellules) ; les autres prennent `T × M_eff × Φ` de la cellule
    /// qui porte le point, à la classe d'altitude du pixel, depuis `GET /weather?cell=` (`detail`).
    static func species(info: PointInfo, detail: CellWeather?) -> [PointSpecies] {
        info.terrains.map { id, terrain in
            if info.mode == .terrain {
                return PointSpecies(id: id, terrain: terrain, value: terrain)
            }
            if let value = info.layerValues[id] {
                return PointSpecies(id: id, terrain: terrain, value: value)
            }
            let cellFactor = factor(detail: detail, species: id, date: info.date, altKey: info.altKey)
            return PointSpecies(id: id, terrain: terrain, value: cellFactor.map { terrain * $0 })
        }
    }

    /// `M_eff × Φ` de la cellule pour une espèce, un jour et une classe ; `nil` si l'API ne l'a pas.
    static func factor(detail: CellWeather?, species: String, date: String?, altKey: String?) -> Double? {
        guard let date, let altKey else { return nil }
        return detail?.species[species]?.first { $0.date == date }?.byAlt[altKey]?.factor
    }

    /// Les espèces par famille, sans `featured` (elle a sa place en tête de fiche) : la famille de
    /// l'espèce mise en avant d'abord, puis les autres par meilleur score décroissant ; dans une
    /// famille, par score décroissant. Une espèce sans score passe après les autres.
    static func families(_ species: [PointSpecies], catalog: SpeciesCatalog, featured: String?) -> [PointFamily] {
        let name = { (id: String) in catalog.species[id]?.names?.fr ?? id }
        let featuredGroup = featured.map { catalog.species[$0]?.group?.id ?? "" }
        var groups: [String: (title: String, species: [PointSpecies])] = [:]
        for item in species where item.id != featured {
            let group = catalog.species[item.id]?.group
            groups[group?.id ?? "", default: (title: group?.fr ?? ungroupedTitle, species: [])].species.append(item)
        }
        let families = groups.map { id, group in
            PointFamily(
                id: id, title: group.title,
                species: group.species.sorted { a, b in
                    let (x, y) = (a.value ?? -1, b.value ?? -1)
                    return x != y ? x > y : name(a.id).localizedStandardCompare(name(b.id)) == .orderedAscending
                }
            )
        }
        return families.sorted { a, b in
            let (first, second) = (a.id == featuredGroup, b.id == featuredGroup)
            if first != second { return first }
            let (x, y) = (a.best ?? -1, b.best ?? -1)
            return x != y ? x > y : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}
