import ChampisScoring
import Foundation
import SwiftUI

/// Onglet Mes coins (refonte UX, lot 1) : la réponse à « j'y vais ce week-end ou pas ? ».
/// Liste classée par score du jour, libellé de la palette et espèce porteuse, tendance en mots ;
/// jamais un chiffre avant « Détails ». Toucher un coin ouvre sa fiche en feuille : la même
/// `PointSheet` que par son épingle sur la carte (`MapModel.openCoin`, révisé le 18 nov. 2026).
/// L'état vide porte la promesse de confidentialité.
struct CoinsScreen: View {
    let model: MapModel
    let router: AppRouter
    @AppStorage("apiBaseURL") private var apiBaseURL = MapScreen.defaultAPIBaseURL
    @State private var showSettings = false
    @State private var showLegalNotice = false

    private var field: FieldModel { model.field }

    var body: some View {
        NavigationStack {
            Group {
                if field.coins.isEmpty {
                    EmptyCoinsView { router.tab = .map }
                } else {
                    coinsList
                }
            }
            .navigationTitle("Mes coins")
            // la même fiche que par l'épingle du coin sur la carte (révisé le 18 nov. 2026)
            .sheet(item: coinSheetBinding) { info in
                PointSheet(info: info, model: model)
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
                guard let id, let coin = field.coins.first(where: { $0.id == id }) else { return }
                model.openCoin(coin)
                router.coinToOpen = nil
            }
        }
    }

    private func retry() {
        let field = field
        Task { await field.retry() }
    }

    /// La fiche d'un coin ouverte depuis cette liste ; en disposition partagée (iPad, Mac),
    /// l'inspecteur la montre et cet écran n'existe pas.
    private var coinSheetBinding: Binding<PointInfo?> {
        Binding(
            get: { model.pointOrigin == .coins ? model.pointInfo : nil },
            set: { if $0 == nil { model.clearSelection() } }
        )
    }

    private var coinsList: some View {
        List {
            if let problem = field.problem {
                Section {
                    ProblemView(problem: problem) { retry() }
                }
            }
            Section {
                ForEach(CoinTrend.order(field.coins, scores: field.coinScores)) { coin in
                    Button {
                        model.openCoin(coin)
                    } label: {
                        HStack {
                            CoinRowView(coin: coin, score: field.coinScores[coin.id], model: model)
                            Spacer(minLength: 8)
                            if model.isInspecting, model.pointCoinID == coin.id {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
            // liseré toujours visible : « très faible » est presque blanc depuis l'échelle linéaire (6 nov. 2026)
            .overlay(Circle().strokeBorder(selected ? Color.primary : Color.secondary.opacity(0.6), lineWidth: selected ? 1.5 : 1))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var fill: Color {
        guard let value, let threshold = model.classify(value) else { return .clear }
        return Color(hex: threshold.hex)
    }
}

/// Les onze pastilles J−3 → J+7, le jour abrégé et son numéro sous chacune (« sam. » / « 7 »,
/// étape A : plus d'initiale ambiguë), aujourd'hui marqué. `interactive: false` dans la fiche d'un
/// point : la carte reste sur aujourd'hui, les pastilles se lisent sans changer de jour.
struct CoinDaysView: View {
    let days: [CoinDay]
    let today: String
    @Binding var selected: String
    let model: MapModel
    var interactive = true

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.date) { day in
                if interactive {
                    Button {
                        selected = day.date
                    } label: {
                        dayLabel(day)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityLabel(day))
                    .accessibilityAddTraits(day.date == selected ? .isSelected : [])
                } else {
                    dayLabel(day)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(accessibilityLabel(day))
                }
            }
        }
    }

    private func dayLabel(_ day: CoinDay) -> some View {
        VStack(spacing: 2) {
            ScoreDot(value: day.value, model: model, size: 14, selected: interactive && day.date == selected)
                .padding(.bottom, 2)
            Text(CoinTrend.shortWeekday(iso: day.date))
            Text("\(CoinTrend.dayOfMonth(iso: day.date))")
        }
        .font(.caption2)
        .fontWeight(day.date == today ? .bold : .regular)
        .foregroundStyle(day.date == today ? .primary : .secondary)
        .opacity(day.date < today ? 0.6 : 1)
        .frame(maxWidth: .infinity)
    }

    private func accessibilityLabel(_ day: CoinDay) -> String {
        let label = day.value.flatMap { model.classify($0)?.fr } ?? "pas de météo"
        return "\(CoinTrend.shortDay(iso: day.date)) : \(label)"
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
                "Ils restent sur cet appareil et sur le serveur sous un identifiant pseudonyme, jamais partagés."
            )
        } actions: {
            Button("Ouvrir la carte", action: openMap)
                .buttonStyle(.borderedProminent)
        }
    }
}
