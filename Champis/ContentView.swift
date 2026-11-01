import SwiftUI

/// Racine de l'app (refonte UX, lot 1) : trois onglets, une question chacun. Mes coins (quand ?),
/// Carte (où ?), Comprendre (pourquoi ?). L'app s'ouvre toujours sur la carte (décision du
/// 1er nov. 2026) ; une notification bascule sur Mes coins et ouvre le coin concerné. Lot 3 : sur
/// iPad en largeur régulière et sur Mac, barre latérale et inspecteur (`SplitContentView`).
struct ContentView: View {
    @AppStorage("apiBaseURL") private var apiBaseURL = MapScreen.defaultAPIBaseURL
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
                tabs
            }
        }
        .task {
            await model.start(apiBaseURL: MapScreen.url(from: apiBaseURL))
        }
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

    private var tabs: some View {
        TabView(selection: tabBinding) {
            Tab("Mes coins", systemImage: "star", value: AppRouter.Tab.coins) {
                CoinsScreen(model: model, router: router)
            }
            Tab("Carte", systemImage: "map", value: AppRouter.Tab.map) {
                MapScreen(model: model)
            }
            Tab("Comprendre", systemImage: "book", value: AppRouter.Tab.understand) {
                UnderstandScreen(model: model)
            }
        }
    }

    private var tabBinding: Binding<AppRouter.Tab> {
        Binding(get: { router.tab }, set: { router.tab = $0 })
    }
}

#Preview {
    ContentView()
}
