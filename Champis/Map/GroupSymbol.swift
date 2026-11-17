import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Symbole d'une famille dans le menu du sélecteur d'espèce (16 nov. 2026) : un SF Symbol maison
/// par groupe du référentiel, `Group-<groupe>` dans le catalogue d'assets, dessiné et écrit par
/// `scripts/group-symbols.py`. Aucun groupe n'est nommé ici : un groupe sans symbole (nouveau dans
/// le référentiel, pas encore dessiné) s'affiche sans icône, comme les espèces seules.
nonisolated enum GroupSymbol {
    static let prefix = "Group-"

    /// Nom du symbole d'une couche ; `nil` pour une espèce seule.
    static func name(for key: LayerKey) -> String? {
        guard case .group(let id) = key else { return nil }
        return prefix + id
    }

    /// Nom du symbole dans le catalogue d'assets, s'il y est.
    static func assetName(for key: LayerKey) -> String? {
        guard let name = name(for: key) else { return nil }
        #if os(iOS)
        return UIImage(named: name) == nil ? nil : name
        #else
        return NSImage(named: name) == nil ? nil : name
        #endif
    }
}
