import Foundation
import Testing
@testable import Champis

#if os(iOS)
import UIKit
#endif

/// Sélecteur d'icône (étape C, lot C6, 8 nov. 2026) : liste lue dans l'Info.plist, noms, ordre,
/// changement et échec, et, dans l'app hôte, les icônes réellement déclarées par le projet.
@MainActor
struct AppIconModelTests {
    /// Le système, sans `UIApplication` : retient les appels et peut échouer.
    @MainActor
    final class FakeSwitcher: AppIconSwitcher {
        var supportsAlternateIcons = true
        var alternateIconName: String?
        var failure: (any Error)?
        private(set) var calls: [String?] = []

        func setAlternateIconName(_ name: String?) async throws {
            calls.append(name)
            if let failure { throw failure }
            alternateIconName = name
        }
    }

    struct Refused: Error {}

    /// Un `CFBundleIcons` comme Xcode l'écrit : une entrée par icône alternative.
    static func icons(_ names: [String], primary: Bool = false) -> [String: Any] {
        var icons: [String: Any] = [
            "CFBundleAlternateIcons": Dictionary(uniqueKeysWithValues: names.map { ($0, ["CFBundleIconName": $0]) })
        ]
        if primary {
            icons["CFBundlePrimaryIcon"] = ["CFBundleIconName": "AppIcon"]
        }
        return icons
    }

    static let info: [String: Any] = [
        "CFBundleIcons": icons(["Icon-boletus_edulis", "Icon-cantharellus_cibarius", "Autre"], primary: true),
        "CFBundleIcons~ipad": icons(["Icon-boletus_edulis", "Icon-boletus_aereus"]),
    ]

    @Test("Icônes d'espèce lues dans l'Info.plist, iPhone et iPad réunis, préfixe Icon- seulement")
    func alternatesFromInfo() {
        let names = AppIconChoice.alternates(in: Self.info).map(\.alternateName)
        #expect(names == ["Icon-boletus_aereus", "Icon-boletus_edulis", "Icon-cantharellus_cibarius"])
        #expect(AppIconChoice.alternates(in: nil).isEmpty)
        let primaryOnly: [String: Any] = ["CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconName": "AppIcon"]]]
        #expect(AppIconChoice.alternates(in: primaryOnly).isEmpty)
    }

    @Test("Espèce et aperçu d'une icône ; l'icône principale a l'aperçu champis")
    func previewNames() {
        let edulis = AppIconChoice(alternateName: "Icon-boletus_edulis")
        #expect(edulis.speciesID == "boletus_edulis")
        #expect(edulis.previewName == "IconPreview-boletus_edulis")
        #expect(AppIconChoice.primary.speciesID == nil)
        #expect(AppIconChoice.primary.previewName == "IconPreview-champis")
        #expect(AppIconChoice.primary.alternateName == nil)
    }

    @Test("L'icône principale d'abord ; sans icônes alternatives, le sélecteur n'est pas proposé")
    func choicesAndAvailability() {
        let model = AppIconModel(switcher: FakeSwitcher(), info: Self.info)
        #expect(model.choices.first == AppIconChoice.primary)
        #expect(model.choices.count == 4)
        #expect(model.isAvailable)

        let unsupported = FakeSwitcher()
        unsupported.supportsAlternateIcons = false
        #expect(!AppIconModel(switcher: unsupported, info: Self.info).isAvailable)
        #expect(!AppIconModel(switcher: FakeSwitcher(), info: nil).isAvailable)
    }

    @Test("Noms : Champis, le nom français du catalogue, à défaut le nom latin tiré de l'identifiant")
    func titles() throws {
        let catalog = try Fixtures.decode(SpeciesCatalog.self, Fixtures.catalogJSON)
        let model = AppIconModel(switcher: FakeSwitcher(), info: Self.info)
        let edulis = AppIconChoice(alternateName: "Icon-boletus_edulis")
        #expect(model.title(for: AppIconChoice.primary, catalog: catalog) == "Champis")
        #expect(model.title(for: edulis, catalog: catalog) == "Cèpe de Bordeaux")
        #expect(model.title(for: edulis, catalog: nil) == "Boletus edulis")
    }

    @Test("Ordre : l'icône principale, puis les espèces par nom affiché")
    func ordering() throws {
        let catalog = try Fixtures.decode(SpeciesCatalog.self, Fixtures.catalogJSON)
        let model = AppIconModel(switcher: FakeSwitcher(), info: Self.info)
        let titles = model.ordered(catalog: catalog).map { model.title(for: $0, catalog: catalog) }
        #expect(titles == ["Champis", "Cèpe bronzé", "Cèpe de Bordeaux", "Girolle"])
    }

    @Test("Choisir une icône : le système reçoit son nom, la coche suit ; l'icône principale passe nil")
    func selecting() async {
        let switcher = FakeSwitcher()
        let model = AppIconModel(switcher: switcher, info: Self.info)
        #expect(model.isSelected(AppIconChoice.primary))

        let girolle = AppIconChoice(alternateName: "Icon-cantharellus_cibarius")
        await model.select(girolle)
        #expect(model.isSelected(girolle))
        #expect(model.selected == girolle)
        #expect(!model.isChanging(girolle))

        await model.select(girolle)  // déjà en service : aucun appel
        await model.select(AppIconChoice.primary)
        #expect(model.isSelected(AppIconChoice.primary))
        #expect(switcher.calls == ["Icon-cantharellus_cibarius", nil])
    }

    @Test("Échec du système : la coche ne bouge pas, le message est en clair")
    func failing() async {
        let switcher = FakeSwitcher()
        switcher.failure = Refused()
        let model = AppIconModel(switcher: switcher, info: Self.info)
        await model.select(AppIconChoice(alternateName: "Icon-boletus_edulis"))
        #expect(model.isSelected(AppIconChoice.primary))
        #expect(model.problem?.text == "L'icône n'a pas pu être changée")
        #expect(model.problem?.retryable == false)
    }

    @Test("L'icône en service est relue au système")
    func refreshing() {
        let switcher = FakeSwitcher()
        let model = AppIconModel(switcher: switcher, info: Self.info)
        switcher.alternateIconName = "Icon-boletus_aereus"
        model.refresh()
        #expect(model.selected.speciesID == "boletus_aereus")
    }

    #if os(iOS)
    @Test("Dans l'app : une icône par aquarelle déclarée par le projet, chacune avec son aperçu")
    func bundledIcons() {
        let icons = AppIconChoice.alternates(in: Bundle.main.infoDictionary)
        #expect(icons.count >= 10)
        for choice in [AppIconChoice.primary] + icons {
            #expect(UIImage(named: choice.previewName) != nil, "aperçu manquant : \(choice.previewName)")
        }
    }
    #endif
}
