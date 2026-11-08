import ChampisScoring
import Foundation
import Observation

/// Modèle du sélecteur d'icône (étape C, lot C6, 8 nov. 2026) : l'icône principale puis une icône
/// par aquarelle d'espèce, l'icône en service et son changement. Ouvert à tous pour l'instant :
/// les icônes récompenseront le soutien quand celui-ci existera.
@Observable
final class AppIconModel {
    /// L'icône principale, puis les icônes d'espèce déclarées par l'Info.plist.
    let choices: [AppIconChoice]
    private(set) var selectedID: AppIconChoice.ID
    /// L'icône en cours de changement, le temps de l'appel au système.
    private(set) var changingID: AppIconChoice.ID?
    private(set) var problem: Problem?
    private let switcher: any AppIconSwitcher

    init(switcher: any AppIconSwitcher, info: [String: Any]? = Bundle.main.infoDictionary) {
        self.switcher = switcher
        let alternates = switcher.supportsAlternateIcons ? AppIconChoice.alternates(in: info) : []
        choices = [.primary] + alternates
        selectedID = switcher.alternateIconName ?? AppIconChoice.primary.id
    }

    /// Le sélecteur n'a de sens qu'avec au moins une icône d'espèce.
    var isAvailable: Bool { choices.count > 1 }

    var selected: AppIconChoice { choices.first { $0.id == selectedID } ?? .primary }

    func isSelected(_ choice: AppIconChoice) -> Bool { choice.id == selectedID }

    func isChanging(_ choice: AppIconChoice) -> Bool { choice.id == changingID }

    /// Nom affiché : « Champis » pour l'icône principale ; sinon le nom français de l'espèce donné
    /// par l'API, à défaut (catalogue pas encore chargé) le nom latin tiré de l'identifiant.
    func title(for choice: AppIconChoice, catalog: SpeciesCatalog?) -> String {
        guard let id = choice.speciesID else { return "Champis" }
        if let name = catalog?.species[id]?.names?.fr {
            return name
        }
        let latin = id.replacingOccurrences(of: "_", with: " ")
        return latin.prefix(1).uppercased() + latin.dropFirst()
    }

    /// L'icône principale d'abord, puis les espèces par nom affiché.
    func ordered(catalog: SpeciesCatalog?) -> [AppIconChoice] {
        let species = choices.filter { $0.speciesID != nil }.sorted {
            title(for: $0, catalog: catalog).localizedStandardCompare(title(for: $1, catalog: catalog)) == .orderedAscending
        }
        return choices.filter { $0.speciesID == nil } + species
    }

    func select(_ choice: AppIconChoice) async {
        guard choice.id != selectedID, changingID == nil else { return }
        changingID = choice.id
        problem = nil
        defer { changingID = nil }
        do {
            try await switcher.setAlternateIconName(choice.alternateName)
            selectedID = choice.id
        } catch {
            problem = Problem("L'icône n'a pas pu être changée", detail: Problem.technical(error), retryable: false)
        }
    }

    /// Relit l'icône en service, au cas où elle aurait changé hors de l'écran.
    func refresh() {
        selectedID = switcher.alternateIconName ?? AppIconChoice.primary.id
    }
}
