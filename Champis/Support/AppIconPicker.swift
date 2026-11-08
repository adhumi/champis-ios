#if os(iOS)
import SwiftUI
import UIKit

/// « Icône de l'app », dans les réglages (étape C, lot C6, 8 nov. 2026) : une grille à la manière
/// de l'écran d'accueil, sur le fond des listes ; l'icône en service porte un anneau et une coche.
/// Ouvert à tous pour l'instant ; les icônes récompenseront le soutien quand il existera.
struct AppIconPicker: View {
    let model: AppIconModel
    let catalog: SpeciesCatalog?
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 64

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: iconSize + 20), spacing: 12, alignment: .top)],
                    spacing: 20
                ) {
                    ForEach(model.ordered(catalog: catalog)) { choice in
                        AppIconTile(
                            title: model.title(for: choice, catalog: catalog),
                            previewName: choice.previewName,
                            size: iconSize,
                            isSelected: model.isSelected(choice),
                            isChanging: model.isChanging(choice)
                        ) {
                            select(choice)
                        }
                    }
                }
                .padding(16)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
                if let problem = model.problem {
                    ProblemView(problem: problem)
                        .padding(.horizontal, 16)
                }
                Text("Une icône par espèce de la carte, d'après son aquarelle.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Icône de l'app")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.refresh() }
    }

    private func select(_ choice: AppIconChoice) {
        Task { await model.select(choice) }
    }
}

#Preview {
    NavigationStack {
        AppIconPicker(model: AppIconModel(switcher: SystemAppIconSwitcher()), catalog: nil)
    }
}
#endif
