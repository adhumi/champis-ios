import Foundation

/// Une icône du sélecteur (étape C, lot C6, 8 nov. 2026) : l'icône principale, ou celle d'une
/// espèce tirée de son aquarelle (`shared/illustrations/` du référentiel, `scripts/sync-icons.py`).
nonisolated struct AppIconChoice: Identifiable, Hashable, Sendable {
    /// Préfixe des jeux d'icônes d'espèce dans Assets.xcassets : `Icon-<espèce>`.
    static let iconPrefix = "Icon-"
    /// Préfixe des aperçus de la grille : `IconPreview-<espèce>`, `IconPreview-champis` pour l'icône principale.
    static let previewPrefix = "IconPreview-"
    static let primary = AppIconChoice(alternateName: nil)

    /// Le nom passé à `setAlternateIconName` ; nil pour l'icône principale.
    let alternateName: String?

    var id: String { alternateName ?? "" }

    /// L'espèce de l'icône ; nil pour l'icône principale.
    var speciesID: String? {
        guard let alternateName, alternateName.hasPrefix(Self.iconPrefix) else { return nil }
        return String(alternateName.dropFirst(Self.iconPrefix.count))
    }

    var previewName: String { Self.previewPrefix + (speciesID ?? "champis") }

    /// Icônes d'espèce déclarées par l'Info.plist compilé (`CFBundleIcons` et `CFBundleIcons~ipad`
    /// › `CFBundleAlternateIcons`, écrits par Xcode d'après `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`) :
    /// aucune liste d'espèces dans le code. Triées par nom de jeu.
    static func alternates(in info: [String: Any]?) -> [AppIconChoice] {
        let names = ["CFBundleIcons", "CFBundleIcons~ipad"].flatMap { key -> [String] in
            let icons = info?[key] as? [String: Any]
            let alternates = icons?["CFBundleAlternateIcons"] as? [String: Any]
            return alternates.map { Array($0.keys) } ?? []
        }
        return Set(names)
            .filter { $0.hasPrefix(iconPrefix) }
            .sorted()
            .map { AppIconChoice(alternateName: $0) }
    }
}
