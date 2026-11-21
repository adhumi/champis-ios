import SwiftUI

/// Mes coins sur iPhone (19 nov. 2026 : plus de barre d'onglets) : une feuille permanente posée
/// sur la carte. Au repos c'est une barre en bas de l'écran, de la hauteur de la barre de
/// navigation et pas plus : le contenu est masqué tant qu'elle est repliée, rien ne dépasse dessous.
/// On la tire, ou on la touche, pour ouvrir la liste des coins et le Guide. La carte reste utilisable derrière tant que la
/// feuille n'est pas en grand. Elle porte aussi ce que la carte présente (fiche d'un point,
/// légende, réglages, alertes : `MapPresentations`), qu'une vue déjà couverte par une feuille ne
/// peut pas présenter elle-même.
///
/// `AppRouter.tab` garde son sens sans onglets : `.map` replie la feuille en barre (« Voir sur la
/// carte »), `.coins` l'ouvre (notification d'un coin).
struct CoinsPanel: View {
    /// Hauteur de la barre au repos : celle de la barre de navigation d'une feuille, poignée
    /// comprise (demande d'Adrien, 21 nov. 2026).
    static let barHeight: CGFloat = 56
    static let bar = PresentationDetent.height(barHeight)

    let model: MapModel
    let router: AppRouter
    @Binding var showLegend: Bool
    @Binding var showSettings: Bool
    @State private var detent = CoinsPanel.bar

    var body: some View {
        CoinsScreen(model: model, router: router, collapsed: detent == Self.bar)
            // au repos, toute la barre est une cible : la toucher ouvre la feuille (le titre de la
            // barre de navigation reste celui du système, sans bouton ni sous-titre)
            .overlay {
                if detent == Self.bar {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { detent = .large }
                        .accessibilityLabel("Mes coins")
                        .accessibilityHint("Ouvre la liste des coins")
                        .accessibilityAddTraits(.isButton)
                }
            }
        .presentationDetents([Self.bar, .medium, .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
        .modifier(MapPresentations(model: model, layout: .compact, showLegend: $showLegend, showSettings: $showSettings))
        .onChange(of: router.tab) { _, tab in
            if tab == .map, detent != Self.bar {
                detent = Self.bar
            } else if tab == .coins, detent == Self.bar {
                detent = .large
            }
        }
        .onChange(of: detent) { _, new in
            let tab: AppRouter.Tab = new == Self.bar ? .map : .coins
            if router.tab != tab {
                router.tab = tab
            }
        }
    }
}
