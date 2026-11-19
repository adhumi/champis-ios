import SwiftUI

/// Racine de l'app. Sur iPhone, plus de barre d'onglets depuis le 19 nov. 2026 : la carte (où ?)
/// en plein écran, et Mes coins (quand ?, avec le Guide dessous : pourquoi ?) dans une feuille
/// permanente que l'on tire depuis une barre en bas de l'écran (`CoinsPanel`) ; l'onglet Guide du lot 1 de la refonte UX est retiré.
/// L'app s'ouvre toujours sur la carte (décision du
/// 1er nov. 2026) ; une notification bascule sur Mes coins et ouvre le coin concerné. Lot 3 : sur
/// iPad en largeur régulière et sur Mac, barre latérale et inspecteur (`SplitContentView`).
struct ContentView: View {
    @AppStorage("apiBaseURL") private var apiBaseURL = MapScreen.defaultAPIBaseURL
    /// Première ouverture (lot 4) : trois cartes puis « Commencer », une seule fois.
    @AppStorage("onboardingDone") private var onboardingDone = false
    @State private var model = MapModel(
        apiBaseURL: URL(string: MapScreen.defaultAPIBaseURL)!, diskCache: try? DiskTileCache.default()
    )
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    private var router: AppRouter { AppRouter.shared }

    var body: some View {
        Group {
            if isSplit {
                SplitContentView(model: model, router: router)
            } else {
                // iPhone : la carte, et Mes coins en feuille permanente par-dessus (`CoinsPanel`) ;
                // la feuille attend la fin de la première ouverture, qui se présente d'abord
                MapScreen(model: model, showsPanel: onboardingDone)
            }
        }
        .task {
            await model.start(apiBaseURL: MapScreen.url(from: apiBaseURL))
        }
        #if os(iOS)
        .fullScreenCover(isPresented: onboardingBinding) {
            OnboardingView(model: model) { onboardingDone = true }
        }
        #else
        .sheet(isPresented: onboardingBinding) {
            OnboardingView(model: model) { onboardingDone = true }
                .frame(minWidth: 480, minHeight: 560)
        }
        #endif
        .onChange(of: apiBaseURL) { _, newValue in
            Task { await model.start(apiBaseURL: MapScreen.url(from: newValue)) }
        }
    }

    private var isSplit: Bool {
        #if os(macOS)
        true
        #else
        sizeClass == .regular
        #endif
    }

    private var onboardingBinding: Binding<Bool> {
        Binding(get: { !onboardingDone }, set: { if !$0 { onboardingDone = true } })
    }
}

#Preview {
    ContentView()
}
