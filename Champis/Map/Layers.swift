import ChampisScoring
import Foundation

/// Ce que l'utilisateur choisit sur la carte : un groupe d'affichage (cèpes, girolles) ou une
/// espèce seule. Règle 9 du modèle : l'UI montre le groupe, dont le score est le max des espèces.
nonisolated enum LayerKey: Hashable, Sendable {
    case species(String)
    case group(String)

    var id: String {
        switch self {
        case .species(let s): "s:" + s
        case .group(let g): "g:" + g
        }
    }
}

nonisolated struct Layer: Identifiable, Hashable, Sendable {
    let key: LayerKey
    let title: String
    /// Identifiants d'espèces de la couche, triés.
    let members: [String]

    var id: LayerKey { key }
}

nonisolated enum LayerCatalog {
    /// Groupes d'abord (ordre alphabétique du libellé), puis chaque espèce par son nom français.
    static func layers(from catalog: SpeciesCatalog) -> [Layer] {
        var groups: [String: (fr: String, members: [String])] = [:]
        for (id, sp) in catalog.species {
            guard let g = sp.group else { continue }
            groups[g.id, default: (fr: g.fr, members: [])].members.append(id)
        }
        let groupLayers = groups
            .map { Layer(key: .group($0.key), title: $0.value.fr, members: $0.value.members.sorted()) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let speciesLayers = catalog.species
            .map { Layer(key: .species($0.key), title: $0.value.names?.fr ?? $0.key, members: [$0.key]) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return groupLayers + speciesLayers
    }
}
