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
            #if os(macOS)
            // Sur Mac, le libellé d'un menu de barre d'outils montre une image à sa taille propre :
            // `frame` et `clipShape` n'y font rien, et l'aquarelle de 300 px couvrait la carte
            // (18 nov. 2026). L'image est donc faite à la bonne taille, déjà ronde.
            if let image = Self.sized(name, side: size) {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .frame(width: size, height: size)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                    .accessibilityHidden(true)
            }
            #else
            Image(name)
                // une image de barre d'outils est sinon teintée comme un symbole
                .renderingMode(.original)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                .accessibilityHidden(true)
            #endif
        }
    }

    #if os(macOS)
    /// L'aperçu redessiné en disque de `side` points : sa taille propre est alors celle voulue.
    static func sized(_ name: String, side: CGFloat) -> NSImage? {
        guard let source = NSImage(named: name) else { return nil }
        let whole = source.size
        let square = min(whole.width, whole.height)
        guard square > 0, side > 0 else { return nil }
        // le carré central de l'aquarelle, comme `scaledToFill` puis le disque
        let from = NSRect(x: (whole.width - square) / 2, y: (whole.height - square) / 2, width: square, height: square)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            source.draw(in: rect, from: from, operation: .sourceOver, fraction: 1)
            return true
        }
    }
    #endif

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
