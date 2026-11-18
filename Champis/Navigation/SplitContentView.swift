import SwiftUI

/// iPad et Mac (refonte UX, lot 3, décision du 1er nov. 2026) : la barre latérale porte Mes coins
/// dépliés, Carte et les quatre entrées du Guide (19 nov. 2026 : plus d'écran Guide, les réglages
/// s'ouvrent depuis la barre latérale) ; la carte occupe le détail ; la fiche d'un point ou d'un coin
/// s'ouvre dans l'inspecteur, jamais en feuille. Choisir un coin recentre la carte.
struct SplitContentView: View {
    nonisolated enum Item: Hashable, Sendable {
        case coin(UUID)
        case map
        /// Un article du Guide, par son identifiant.
        case article(String)
    }

    let model: MapModel
    let router: AppRouter
    @State private var selection: Item? = .map
    @State private var columns = NavigationSplitViewVisibility.automatic
    @State private var guide = GuideCards.cards(from: Texts.index())
    @AppStorage("apiBaseURL") private var apiBaseURL = MapScreen.defaultAPIBaseURL
    @State private var showSettings = false
    @State private var showLegalNotice = false

    private var field: FieldModel { model.field }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
        } detail: {
            detail
        }
        .task {
            await field.refreshCoinScores()
            model.completeCoinsInBackground()
        }
        .onChange(of: router.coinToOpen, initial: true) { _, id in
            guard let id, field.coins.contains(where: { $0.id == id }) else { return }
            selection = .coin(id)
            router.coinToOpen = nil
        }
        .onChange(of: router.tab) { _, tab in
            // « Ouvrir la carte » depuis un article ou l'état vide
            if tab == .map, case .article? = selection {
                selection = .map
            }
        }
        .onChange(of: selection) { _, item in
            if case .coin(let id)? = item, let coin = field.coins.first(where: { $0.id == id }) {
                model.center(latitude: coin.lat, longitude: coin.lon)
                // la même fiche que par l'épingle du coin (révisé le 18 nov. 2026)
                model.openCoin(coin)
            }
        }
        .onChange(of: model.pointCoinID) { _, id in
            // fiche du coin fermée par sa croix : la barre latérale revient à la carte
            if id == nil, case .coin? = selection {
                selection = .map
            }
        }
        .onChange(of: field.coins) { _, coins in
            // coin supprimé depuis l'inspecteur : retour à la carte
            if case .coin(let id)? = selection, !coins.contains(where: { $0.id == id }) {
                selection = .map
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Mes coins") {
                if field.coins.isEmpty {
                    Text("Aucun coin. Un appui long sur la carte, puis « Ajouter à mes coins ».")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(CoinTrend.order(field.coins, scores: field.coinScores)) { coin in
                    CoinRowView(coin: coin, score: field.coinScores[coin.id], model: model)
                        .tag(Item.coin(coin.id))
                }
            }
            Section {
                Label("Carte", systemImage: "map").tag(Item.map)
            }
            if !guide.isEmpty {
                Section("Guide") {
                    ForEach(guide) { card in
                        GuideRow(card: card).tag(Item.article(card.id))
                    }
                }
            }
        }
        .navigationTitle("Champis")
        .refreshable { await field.refreshCoinScores() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Label("Réglages", systemImage: "slider.horizontal.3")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model, apiBaseURL: $apiBaseURL, showLegalNotice: $showLegalNotice)
        }
        .alert(LegalNotice.title, isPresented: $showLegalNotice) {
            Button("OK") {}
        } message: {
            Text(LegalNotice.text)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .article(let id):
            NavigationStack {
                if let card = guide.first(where: { $0.id == id }) {
                    ArticleView(article: card.article, model: model)
                }
            }
        default:
            MapScreen(model: model, layout: .split)
                .inspector(isPresented: inspectorBinding) {
                    inspector
                        .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
                }
        }
    }

    /// Le point touché l'emporte, puis le coin choisi.
    @ViewBuilder
    private var inspector: some View {
        if let info = model.pointInfo {
            PointSheet(info: info, model: model)
        } else if case .coin? = selection {
            // la fiche du coin se lit (tuiles, météo)
            ProgressView()
        }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: {
                if case .coin? = selection { return true }
                return model.pointInfo != nil
            },
            set: { shown in
                guard !shown else { return }
                model.clearSelection()
                if case .coin? = selection { selection = .map }
            }
        )
    }
}
