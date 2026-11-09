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
    /// Nom latin, sous le nom français dans le sélecteur : celui de l'espèce, ou pour un groupe ses
    /// genres suivis de « spp. » (« Boletus spp. », « Lactarius, Lactifluus spp. »). Vide s'il manque.
    let latin: String
    /// Espèce dont l'aquarelle sert de vignette (`SpeciesThumbnail`) : l'espèce elle-même, ou pour un
    /// groupe celle au nom français le plus court (à égalité, la première dans l'ordre alphabétique).
    let illustration: String?

    init(key: LayerKey, title: String, members: [String], latin: String = "", illustration: String? = nil) {
        self.key = key
        self.title = title
        self.members = members
        self.latin = latin
        self.illustration = illustration
    }

    var id: LayerKey { key }

    var isGroup: Bool {
        if case .group = key { return true }
        return false
    }
}

/// Mêmes règles que le sélecteur d'espèce du site (`layerItems` de `champis-web/web/site.js`,
/// 9 nov. 2026) : nom latin d'un groupe tiré des genres de ses espèces, vignette du groupe tirée de
/// l'espèce au nom le plus court. Rien n'est nommé dans le code : tout vient de `GET /species`.
nonisolated enum LayerCatalog {
    /// Groupes d'abord (ordre alphabétique du libellé), puis chaque espèce par son nom français.
    static func layers(from catalog: SpeciesCatalog) -> [Layer] {
        var groups: [String: (fr: String, members: [String])] = [:]
        for (id, sp) in catalog.species {
            guard let g = sp.group else { continue }
            groups[g.id, default: (fr: g.fr, members: [])].members.append(id)
        }
        let groupLayers = groups
            .map { id, group in
                let members = group.members.sorted()
                return Layer(
                    key: .group(id), title: group.fr, members: members,
                    latin: groupLatin(members.compactMap { catalog.species[$0]?.names?.la }),
                    illustration: lead(members.map { (id: $0, fr: catalog.species[$0]?.names?.fr ?? $0) })
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let speciesLayers = catalog.species
            .map { id, sp in
                Layer(key: .species(id), title: sp.names?.fr ?? id, members: [id], latin: sp.names?.la ?? "", illustration: id)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return groupLayers + speciesLayers
    }

    /// Genres distincts des noms latins (le premier mot), triés, suivis de « spp. » ; vide sans nom.
    static func groupLatin(_ names: [String]) -> String {
        let genera = Set(names.compactMap { $0.split(separator: " ").first.map(String.init) }).sorted()
        return genera.isEmpty ? "" : genera.joined(separator: ", ") + " spp."
    }

    /// L'espèce au nom français le plus court ; à égalité, la première dans l'ordre alphabétique.
    static func lead(_ members: [(id: String, fr: String)]) -> String? {
        members.min { a, b in
            a.fr.count != b.fr.count ? a.fr.count < b.fr.count : a.fr.localizedStandardCompare(b.fr) == .orderedAscending
        }?.id
    }
}
