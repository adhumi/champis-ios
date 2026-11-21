import SwiftUI

/// Mes coins sur iPhone (19 nov. 2026 : plus de barre d'onglets) : une feuille permanente posée
/// sur la carte. Au repos c'est une barre en bas de l'écran, de la hauteur de la barre de
/// navigation et pas plus, qui ne porte que le libellé « Mes coins » : le contenu et la barre de
/// navigation sont masqués tant qu'elle est repliée, rien ne dépasse dessous.
/// On la tire, ou on la touche, pour ouvrir la liste des coins et le Guide. La carte reste utilisable derrière tant que la
/// feuille n'est pas en grand. Elle porte aussi ce que la carte présente (fiche d'un point,
/// légende, réglages, alertes : `MapPresentations`), qu'une vue déjà couverte par une feuille ne
/// peut pas présenter elle-même.
///
/// `AppRouter.tab` garde son sens sans onglets : `.map` replie la feuille en barre (« Voir sur la
/// carte »), `.coins` l'ouvre (notification d'un coin).
struct CoinsPanel: View {
    /// Hauteur de la barre au repos : celle d'une barre de navigation (demande d'Adrien,
    /// 21 nov. 2026), le libellé centré dedans.
    static let barHeight: CGFloat = 52
    static let bar = PresentationDetent.height(barHeight)

    let model: MapModel
    let router: AppRouter
    @Binding var showLegend: Bool
    @Binding var showSettings: Bool
    @State private var detent = CoinsPanel.bar

    var body: some View {
        CoinsScreen(model: model, router: router, collapsed: detent == Self.bar)
            // au repos, la barre n'est qu'un libellé centré, sans barre de navigation ni poignée
            // (22 nov. 2026 : le titre du système, calé sous la poignée, n'était pas centré dans la
            // barre) ; la toucher ouvre la feuille
            .overlay {
                if detent == Self.bar {
                    Label("Mes coins", systemImage: "star.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { detent = .large }
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("Ouvre la liste des coins")
                        .accessibilityAddTraits(.isButton)
                        .transition(.opacity)
                }
            }
            .animation(.default, value: detent == Self.bar)
        .presentationDetents([Self.bar, .medium, .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationDragIndicator(detent == Self.bar ? .hidden : .visible)
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
