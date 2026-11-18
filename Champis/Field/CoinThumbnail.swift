import CoreLocation
import Foundation
import MapKit
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Miniature de carte d'un coin dans la liste Mes coins (18 nov. 2026) : un aperçu fixe du fond
/// Plans standard autour de l'endroit, sans la couche Champis, avec une étoile au centre. L'image
/// vient de `MKMapSnapshotter` et se garde en mémoire par endroit et par apparence ; tant qu'elle
/// n'est pas là (ou hors ligne), un fond neutre porte l'étoile.
struct CoinThumbnail: View {
    let latitude: Double
    let longitude: Double
    var side: CGFloat = 56
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var image: Image?

    var body: some View {
        ZStack {
            if let image {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
            }
            Image(systemName: "star.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .shadow(radius: 1)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
        .task(id: key) {
            if let cached = CoinSnapshots.cache[key] {
                image = cached
                return
            }
            let dark = colorScheme == .dark
            let made = await CoinSnapshots.make(
                latitude: latitude, longitude: longitude, side: side, dark: dark, scale: displayScale
            )
            guard !Task.isCancelled, let made else { return }
            CoinSnapshots.cache[key] = made
            image = made
        }
    }

    /// Un aperçu par endroit (au dix-millième de degré), par apparence et par taille.
    private var key: String {
        let lat = String(format: "%.4f", latitude)
        let lon = String(format: "%.4f", longitude)
        let style = colorScheme == .dark ? "sombre" : "clair"
        return "\(lat),\(lon),\(style),\(Int(side))"
    }
}

/// Aperçus de carte des coins : fabrication et mémoire, pour la durée du lancement.
enum CoinSnapshots {
    /// Aperçus déjà faits, par clé de `CoinThumbnail`.
    static var cache: [String: Image] = [:]

    /// Côté du carré de terrain montré, en mètres.
    nonisolated static let spanMeters: CLLocationDistance = 1500

    /// Un aperçu carré du fond Plans standard centré sur l'endroit ; `nil` si Plans ne répond pas.
    nonisolated static func make(latitude: Double, longitude: Double, side: CGFloat, dark: Bool, scale: CGFloat) async -> Image? {
        let options = MKMapSnapshotter.Options()
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        options.region = MKCoordinateRegion(center: center, latitudinalMeters: spanMeters, longitudinalMeters: spanMeters)
        options.size = CGSize(width: side, height: side)
        options.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        #if os(iOS)
        options.traitCollection = UITraitCollection { traits in
            traits.userInterfaceStyle = dark ? .dark : .light
            traits.displayScale = scale
        }
        #elseif os(macOS)
        options.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        #endif
        let snapshotter = MKMapSnapshotter(options: options)
        guard let snapshot = try? await snapshotter.start() else { return nil }
        #if os(iOS)
        return Image(uiImage: snapshot.image)
        #else
        return Image(nsImage: snapshot.image)
        #endif
    }
}
