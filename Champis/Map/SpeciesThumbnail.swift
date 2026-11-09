import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Vignette naturaliste d'une couche, dans le bouton du sélecteur d'espèce (9 nov. 2026) :
/// l'aquarelle de l'espèce dans un cercle. C'est l'aperçu déjà embarqué pour le sélecteur d'icônes
/// (`IconPreview-<espèce>`, 300 px, écrit par `scripts/sync-icons.py` depuis `shared/illustrations/`
/// du référentiel) : aucune image en plus dans l'app. Une espèce dont l'app n'a pas encore
/// l'aquarelle n'a pas de vignette, le nom suffit.
struct SpeciesThumbnail: View {
    let species: String?
    var size: CGFloat = 28

    var body: some View {
        if let name = Self.assetName(for: species) {
            Image(name)
                // une image de barre d'outils est sinon teintée comme un symbole
                .renderingMode(.original)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                .accessibilityHidden(true)
        }
    }

    /// Nom de l'aperçu dans le catalogue d'assets, s'il y est.
    static func assetName(for species: String?) -> String? {
        guard let species else { return nil }
        let name = AppIconChoice.previewPrefix + species
        #if os(iOS)
        return UIImage(named: name) == nil ? nil : name
        #else
        return NSImage(named: name) == nil ? nil : name
        #endif
    }
}
