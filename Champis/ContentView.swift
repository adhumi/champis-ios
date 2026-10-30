import ChampisScoring
import SwiftUI

/// Modèle de la vue d'accueil (MVVM, `@Observable`, isolé au MainActor par défaut).
///
/// Squelette : la carte, le sélecteur d'espèce et le curseur de jour viennent en phase 4.
@Observable
final class ContentModel {
    /// Version du modèle de scoring que l'app sait calculer (contrat `shared/vectors`).
    var scoringVersion = ChampisScoring.supportedScoringVersion
}

struct ContentView: View {
    @State private var model = ContentModel()

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Champis")
                .font(.largeTitle.bold())
            Text("Scoring \(model.scoringVersion)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
