import SwiftUI

/// Espèce proposée dans un sélecteur.
nonisolated struct SpeciesOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}
