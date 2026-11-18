import SwiftUI

/// Mes coins sur iPhone (19 nov. 2026 : plus de barre d'onglets) : une feuille permanente posée
/// sur la carte. Au repos c'est une barre en bas de l'écran ; on la tire, ou on touche son titre,
/// pour ouvrir la liste des coins et le Guide. La carte reste utilisable derrière tant que la
/// feuille n'est pas en grand. Elle porte aussi ce que la carte présente (fiche d'un point,
/// légende, réglages, alertes : `MapPresentations`), qu'une vue déjà couverte par une feuille ne
/// peut pas présenter elle-même.
///
/// `AppRouter.tab` garde son sens sans onglets : `.map` replie la feuille en barre (« Voir sur la
/// carte »), `.coins` l'ouvre (notification d'un coin).
struct CoinsPanel: View {
    /// Hauteur de la barre au repos : la poignée et le titre.
    static let barHeight: CGFloat = 84
    static let bar = PresentationDetent.height(barHeight)

    let model: MapModel
    let router: AppRouter
    @Binding var showLegend: Bool
    @Binding var showSettings: Bool
    @State private var detent = CoinsPanel.bar

    var body: some View {
        CoinsScreen(model: model, router: router) {
            // toucher le titre : ouvrir la feuille, ou la replier si elle est ouverte
            detent = detent == Self.bar ? .large : Self.bar
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
