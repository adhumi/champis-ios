import ChampisScoring
import Foundation
import SwiftUI

/// Onglet Mes coins (refonte UX, lot 1) : la réponse à « j'y vais ce week-end ou pas ? ».
/// Liste classée par score du jour, libellé de la palette et espèce porteuse, tendance en mots ;
/// jamais un chiffre avant « Détails ». L'état vide porte la promesse de confidentialité.
struct CoinsScreen: View {
    let model: MapModel
    let router: AppRouter
    @AppStorage("apiBaseURL") private var apiBaseURL = MapScreen.defaultAPIBaseURL
    @State private var path: [UUID] = []
    @State private var showSettings = false
    @State private var showLegalNotice = false

    private var field: FieldModel { model.field }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if field.coins.isEmpty {
                    EmptyCoinsView { router.tab = .map }
                } else {
                    coinsList
                }
            }
            .navigationTitle("Mes coins")
            .navigationDestination(for: UUID.self) { id in
                CoinDetailView(coinID: id, model: model, router: router)
            }
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
            .task { await field.refreshCoinScores() }
            .refreshable { await field.refreshCoinScores() }
            .onChange(of: router.coinToOpen, initial: true) { _, id in
                guard let id, field.coins.contains(where: { $0.id == id }) else { return }
                path = [id]
                router.coinToOpen = nil
            }
        }
    }

    private var coinsList: some View {
        List {
            Section {
                ForEach(CoinTrend.order(field.coins, scores: field.coinScores)) { coin in
                    NavigationLink(value: coin.id) {
                        CoinRowView(coin: coin, score: field.coinScores[coin.id], model: model)
                    }
                }
            } header: {
                if let today = field.coinsToday {
                    Text("Météo du \(MapModel.format(iso: today))")
                } else {
                    Text("Météo en attente")
                }
            } footer: {
                if field.pendingCount > 0 {
                    Text("\(field.pendingCount) observation(s) à envoyer")
                } else if let status = field.status {
                    Text(status)
                }
            }
        }
    }
}

/// Une ligne : nom, pastille et libellé du jour, espèce qui porte le score, tendance.
struct CoinRowView: View {
    let coin: Coin
    let score: ScoredCoin?
    let model: MapModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(coin.name).font(.headline)
            HStack(spacing: 6) {
                ScoreDot(value: score?.score, model: model, size: 10)
                Text(stateText)
            }
            .font(.subheadline)
            if let trend {
                Text(trend).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var stateText: String {
        guard let value = score?.score, let threshold = model.classify(value) else {
            return "pas de météo aujourd'hui"
        }
        if let leading = score?.leading {
            return "\(threshold.fr) · \(model.speciesName(leading).lowercased())"
        }
        return threshold.fr
    }

    private var trend: String? {
        guard let score, let today = model.field.coinsToday, let goodMin = model.goodThreshold else { return nil }
        return CoinTrend.phrase(CoinTrend.kind(days: score.days, today: today, goodMin: goodMin))
    }
}

/// Pastille de couleur de la palette ; grise et vide sans météo. La couleur ne porte jamais seule
/// l'information : elle accompagne toujours un libellé.
struct ScoreDot: View {
    let value: Double?
    let model: MapModel
    var size: CGFloat = 12
    var selected = false

    var body: some View {
        Circle()
            .fill(fill)
            .overlay(Circle().strokeBorder(selected ? Color.primary : Color.secondary.opacity(value == nil ? 0.6 : 0), lineWidth: 1.5))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var fill: Color {
        guard let value, let threshold = model.classify(value) else { return .clear }
        return Color(hex: threshold.hex)
    }
}

/// Les onze pastilles J−3 → J+7, l'initiale du jour sous chacune, aujourd'hui marqué.
struct CoinDaysView: View {
    let days: [CoinDay]
    let today: String
    @Binding var selected: String
    let model: MapModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.date) { day in
                Button {
                    selected = day.date
                } label: {
                    VStack(spacing: 4) {
                        ScoreDot(value: day.value, model: model, size: 14, selected: day.date == selected)
                        Text(CoinTrend.initial(iso: day.date))
                            .font(.caption2)
                            .fontWeight(day.date == today ? .bold : .regular)
                            .foregroundStyle(day.date == today ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(day))
                .accessibilityAddTraits(day.date == selected ? .isSelected : [])
            }
        }
    }

    private func accessibilityLabel(_ day: CoinDay) -> String {
        let label = day.value.flatMap { model.classify($0)?.fr } ?? "pas de météo"
        return "\(CoinTrend.shortDay(iso: day.date)) : \(label)"
    }
}

/// Fiche d'un coin : le jour choisi en mots, les onze jours, Voir sur la carte, Renommer,
/// Supprimer, et les chiffres derrière « Détails ».
struct CoinDetailView: View {
    let coinID: UUID
    let model: MapModel
    let router: AppRouter
    @State private var selectedDay = ""
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    private var field: FieldModel { model.field }
    private var coin: Coin? { field.coins.first { $0.id == coinID } }
    private var score: ScoredCoin? { field.coinScores[coinID] }
    private var today: String { field.coinsToday ?? "" }
    private var day: CoinDay? {
        score?.days.first { $0.date == (selectedDay.isEmpty ? today : selectedDay) }
    }

    var body: some View {
        List {
            if let coin {
                Section {
                    HStack(spacing: 8) {
                        ScoreDot(value: day?.value ?? (selectedDay.isEmpty ? score?.score : nil), model: model, size: 16)
                        Text(headline).font(.title3).fontWeight(.semibold)
                    }
                    .accessibilityElement(children: .combine)
                    Text(subtitle).foregroundStyle(.secondary)
                    if let score, !score.days.isEmpty {
                        CoinDaysView(days: score.days, today: today, selected: selectionBinding, model: model)
                            .padding(.vertical, 4)
                    } else if let trend = trendPhrase {
                        Text(trend).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button {
                        model.focus(latitude: coin.lat, longitude: coin.lon)
                        router.tab = .map
                    } label: {
                        Label("Voir sur la carte", systemImage: "map")
                    }
                }
                Section("Détails") {
                    LabeledContent("Cible", value: model.layerTitle(forTarget: coin.target))
                    LabeledContent("Classe d'altitude", value: "\(coin.altClass) m")
                    ForEach(coin.t.keys.sorted(), id: \.self) { sid in
                        LabeledContent("T · \(model.speciesName(sid))", value: PointSheet.number(coin.t[sid] ?? 0))
                    }
                    if let value = day?.value ?? score?.score {
                        LabeledContent("Score du jour", value: PointSheet.number(value))
                    }
                    if let leading = day?.leading ?? score?.leading, let t = coin.t[leading], t > 0,
                       let value = day?.value ?? score?.score {
                        LabeledContent("M_eff × Φ", value: PointSheet.number(value / t))
                    }
                }
                Section {
                    Button("Renommer") {
                        newName = coin.name
                        renaming = true
                    }
                    Button("Supprimer", role: .destructive) { confirmDelete = true }
                }
            } else {
                Text("Ce coin n'existe plus.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(coin?.name ?? "Coin")
        .alert("Nom du coin", isPresented: $renaming) {
            TextField("Nom", text: $newName)
            Button("Enregistrer") {
                let name = newName
                let field = field
                Task { await field.renameCoin(coinID, to: name) }
            }
            Button("Annuler", role: .cancel) {}
        }
        .confirmationDialog("Supprimer ce coin ?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                let field = field
                Task { await field.removeCoin(coinID) }
                dismiss()
            }
        } message: {
            Text("Le coin est retiré de l'appareil et du serveur.")
        }
        .task { await field.refreshCoinScores() }
    }

    private var selectionBinding: Binding<String> {
        Binding(get: { selectedDay.isEmpty ? today : selectedDay }, set: { selectedDay = $0 })
    }

    private var headline: String {
        let iso = selectedDay.isEmpty ? today : selectedDay
        let value = day?.value ?? (iso == today ? score?.score : nil)
        guard let value, let threshold = model.classify(value) else { return "Pas de météo" }
        return iso == today ? "\(threshold.fr) aujourd'hui" : "\(threshold.fr) \(CoinTrend.weekdayName(iso: iso))"
    }

    private var subtitle: String {
        let iso = selectedDay.isEmpty ? today : selectedDay
        var parts: [String] = []
        if let leading = day?.leading ?? (iso == today ? score?.leading : nil) {
            parts.append(model.speciesName(leading).lowercased())
        }
        if !iso.isEmpty {
            parts.append(MapModel.format(iso: iso))
        }
        return parts.joined(separator: " · ")
    }

    private var trendPhrase: String? {
        guard let score, let goodMin = model.goodThreshold, !today.isEmpty else { return nil }
        return CoinTrend.phrase(CoinTrend.kind(days: score.days, today: today, goodMin: goodMin))
    }
}

/// État vide : le seul endroit où la promesse de confidentialité est écrite en entier.
struct EmptyCoinsView: View {
    let openMap: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Aucun coin pour l'instant", systemImage: "star")
        } description: {
            Text(
                "Ajoutez vos coins depuis la carte : touchez un endroit, puis « Ajouter à mes coins ». " +
                "Ils restent sur cet appareil et sur le serveur sous un identifiant anonyme, jamais partagés."
            )
        } actions: {
            Button("Ouvrir la carte", action: openMap)
                .buttonStyle(.borderedProminent)
        }
    }
}
