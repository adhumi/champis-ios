import SwiftUI

/// iPad et Mac (refonte UX, lot 3, décision du 1er nov. 2026) : la barre latérale porte Mes coins
/// dépliés, Carte et Comprendre ; la carte occupe le détail ; la fiche d'un point, d'un département
/// ou d'un coin s'ouvre dans l'inspecteur, jamais en feuille. Choisir un coin recentre la carte.
struct SplitContentView: View {
    nonisolated enum Item: Hashable, Sendable {
        case coin(UUID)
        case map
        case understand
    }

    let model: MapModel
    let router: AppRouter
    @State private var selection: Item? = .map
    @State private var columns = NavigationSplitViewVisibility.automatic

    private var field: FieldModel { model.field }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
        } detail: {
            detail
        }
        .task { await field.refreshCoinScores() }
        .onChange(of: router.coinToOpen, initial: true) { _, id in
            guard let id, field.coins.contains(where: { $0.id == id }) else { return }
            selection = .coin(id)
            router.coinToOpen = nil
        }
        .onChange(of: router.tab) { _, tab in
            switch tab {
            case .understand: selection = .understand
            case .map where selection == .understand: selection = .map
            default: break
            }
        }
        .onChange(of: selection) { _, item in
            if case .coin(let id)? = item, let coin = field.coins.first(where: { $0.id == id }) {
                model.center(latitude: coin.lat, longitude: coin.lon)
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
                Label("Comprendre", systemImage: "book").tag(Item.understand)
            }
        }
        .navigationTitle("Champis")
        .refreshable { await field.refreshCoinScores() }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .understand:
            UnderstandScreen(model: model)
        default:
            MapScreen(model: model, layout: .split)
                .inspector(isPresented: inspectorBinding) {
                    inspector
                        .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
                }
        }
    }

    /// Le point touché l'emporte, puis le département en vue France, puis le coin choisi.
    @ViewBuilder
    private var inspector: some View {
        if let info = model.pointInfo {
            PointSheet(info: info, model: model)
        } else if let info = model.deptInfo {
            DeptSheet(info: info, model: model)
        } else if case .coin(let id)? = selection {
            NavigationStack {
                CoinDetailView(coinID: id, model: model, router: router)
            }
        }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: {
                if case .coin? = selection { return true }
                return model.pointInfo != nil || model.deptInfo != nil
            },
            set: { shown in
                guard !shown else { return }
                model.clearSelection()
                model.clearDeptInfo()
                if case .coin? = selection { selection = .map }
            }
        )
    }
}
