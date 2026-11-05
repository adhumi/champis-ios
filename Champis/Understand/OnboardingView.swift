import ChampisScoring
import SwiftUI

/// Première ouverture (refonte UX, lot 4) : trois cartes à balayer à la place de la fenêtre
/// légale, un bouton « Commencer », pas de case à cocher. Les couleurs viennent de la palette
/// servie par l'API ; sans réseau au premier lancement, la carte des couleurs reste en mots.
struct OnboardingView: View {
    nonisolated struct Card: Identifiable, Sendable {
        let id: Int
        let icon: String
        let title: String
        let text: String
    }

    static let cards = [
        Card(id: 0, icon: "map", title: "Ce que montrent les couleurs",
             text: "La carte estime, pour chaque carré de forêt et chaque jour, si les conditions sont réunies : le terrain, la météo des dernières semaines et la saison. Cinq mots, du vert foncé au rouge. Transparent : hors forêt ou sans donnée."),
        Card(id: 1, icon: "tree", title: "Cueillir sans nuire",
             text: "Champis indique un potentiel, pas une autorisation. En forêt privée, il faut l'accord du propriétaire ; en forêt publique, la cueillette familiale est tolérée et peut être restreinte par arrêté. Le détail est dans le Guide."),
        Card(id: 2, icon: "lock", title: "Rien n'est collecté",
             text: "Pas de compte. Vos coins et vos observations restent liés à un identifiant anonyme créé par l'app, jamais partagés, effaçables d'un geste. L'app ne tourne pas en arrière-plan."),
    ]

    let model: MapModel
    let done: () -> Void
    @State private var page = 0

    var body: some View {
        VStack(spacing: 20) {
            #if os(iOS)
            TabView(selection: $page) {
                ForEach(Self.cards) { card in
                    cardView(card).tag(card.id)
                }
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            #else
            ScrollView {
                VStack(spacing: 24) {
                    ForEach(Self.cards) { card in
                        cardView(card)
                    }
                }
                .padding()
            }
            #endif
            Button {
                done()
            } label: {
                Text(isLast ? "Commencer" : "Suivant")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(.background)
        .interactiveDismissDisabled()
    }

    private var isLast: Bool {
        #if os(iOS)
        page == Self.cards.count - 1
        #else
        true
        #endif
    }

    private func cardView(_ card: Card) -> some View {
        VStack(spacing: 16) {
            Image(systemName: card.icon)
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .padding(.top, 32)
            Text(card.title).font(.title2).fontWeight(.semibold).multilineTextAlignment(.center)
            Text(card.text).multilineTextAlignment(.center).foregroundStyle(.secondary)
            if card.id == 0, !model.legend.isEmpty {
                HStack(spacing: 10) {
                    ForEach(model.legend, id: \.label) { threshold in
                        VStack(spacing: 4) {
                            Circle().fill(Color(hex: threshold.hex)).frame(width: 16, height: 16)
                            Text(threshold.fr).font(.caption2)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
    }
}
