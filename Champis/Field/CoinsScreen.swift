import ChampisScoring
import Foundation
import SwiftUI

/// Onglet Mes coins (refonte UX, lot 1) : la réponse à « j'y vais ce week-end ou pas ? ».
/// Liste classée par score du jour ; chaque coin avec sa miniature de carte et les espèces qui y
/// valent au moins « moyen » (18 nov. 2026 : un coin est générique, sans en-tête de date ni tendance) ;
/// jamais un chiffre avant « Détails ». Toucher un coin pousse sa fiche dans la pile : la même
/// `PointSheet` que par son épingle sur la carte (`CoinPointView`, `MapModel.openCoin`, 18 nov. 2026).
/// L'état vide porte la promesse de confidentialité. Sous les coins, la section Guide : quatre
/// articles embarqués (`GuideCards`), l'onglet Guide étant retiré depuis le 19 nov. 2026 ; les
/// autres articles se lisent depuis les réglages.
struct CoinsScreen: View {
    let model: MapModel
    let router: AppRouter
    /// Toucher le titre de la liste : la feuille qui la porte s'ouvre ou se replie (`CoinsPanel`).
    var onTitleTap: () -> Void = {}
    @State private var path = NavigationPath()
    /// Les quatre entrées du Guide, sous les coins (19 nov. 2026 : l'onglet Guide est retiré).
    @State private var guide = GuideCards.cards(from: Texts.index())

    private var field: FieldModel { model.field }

    var body: some View {
        NavigationStack(path: $path) {
            coinsList
            .navigationTitle("Mes coins")
            #if os(iOS)
            // la liste vit dans une feuille : un titre en ligne, qui tient dans la barre au repos
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: Article.self) { article in
                ArticleView(article: article, model: model)
            }
            // la même fiche que par l'épingle du coin sur la carte, poussée dans la pile (18 nov. 2026)
            .navigationDestination(for: UUID.self) { id in
                CoinPointView(coinID: id, model: model)
            }
            .toolbar {
                // le titre est un bouton : il ouvre ou replie la feuille ; les réglages sont dans
                // le menu « … » de la carte (19 nov. 2026)
                ToolbarItem(placement: .principal) {
                    Button(action: onTitleTap) {
                        VStack(spacing: 1) {
                            Text("Mes coins").font(.headline)
                            Text(summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Ouvre ou replie la liste des coins")
                }
            }
            // la feuille est là dès le lancement : la liste se charge quand le catalogue est arrivé
            .task(id: model.layers.isEmpty) {
                await field.refreshCoinScores()
                // coins d'avant le 18 nov. 2026 : le terrain de toutes les espèces, une fois, dans
                // une tâche du modèle (quitter cet écran ne l'interrompt pas)
                model.completeCoinsInBackground()
            }
            .refreshable { await field.refreshCoinScores() }
            .onChange(of: router.coinToOpen, initial: true) { _, id in
                guard let id, field.coins.contains(where: { $0.id == id }) else { return }
                path = NavigationPath([id])
                router.coinToOpen = nil
            }
        }
    }

    private func retry() {
        let field = field
        Task { await field.retry() }
    }

    /// Sous le titre, ce que la barre au repos dit des coins : le meilleur du jour, sinon leur nombre.
    private var summary: String {
        Self.summary(coins: field.coins, scores: field.coinScores) { model.classify($0)?.fr }
    }

    /// « Forêt 5G · Bon », « 3 coins », ou l'invitation à en ajouter. Fonction pure, testée.
    nonisolated static func summary(coins: [Coin], scores: [UUID: ScoredCoin], label: (Double) -> String?) -> String {
        guard !coins.isEmpty else { return "Touchez la carte pour ajouter un coin" }
        let best = coins
            .compactMap { coin in scores[coin.id]?.score.map { (coin: coin, value: $0) } }
            .max { $0.value < $1.value }
        if let best, let text = label(best.value) {
            return "\(best.coin.name) · \(text)"
        }
        return coins.count == 1 ? "1 coin" : "\(coins.count) coins"
    }

    private var coinsList: some View {
        List {
            if let problem = field.problem {
                Section {
                    ProblemView(problem: problem) { retry() }
                }
            }
            Section {
                if field.coins.isEmpty {
                    EmptyCoinsView { router.tab = .map }
                }
                ForEach(CoinTrend.order(field.coins, scores: field.coinScores)) { coin in
                    NavigationLink(value: coin.id) {
                        CoinRowView(coin: coin, score: field.coinScores[coin.id], model: model)
                    }
                }
            } footer: {
                if field.pendingCount > 0 {
                    Text("\(field.pendingCount) observation(s) à envoyer")
                }
            }
            if !guide.isEmpty {
                Section("Guide") {
                    ForEach(guide) { card in
                        NavigationLink(value: card.article) {
                            GuideRow(card: card)
                        }
                    }
                }
            }
        }
    }
}

/// Une ligne (18 nov. 2026 : un coin est générique, pas lié à une espèce) : la miniature de carte
/// de l'endroit, le nom, puis une ligne par espèce notée au moins « moyen » aujourd'hui (pastille,
/// nom, libellé ; `CoinTrend.worthSpecies`). Si aucune n'atteint moyen : la pastille et le libellé
/// du coin, sans nom d'espèce. Pas de tendance.
struct CoinRowView: View {
    let coin: Coin
    let score: ScoredCoin?
    let model: MapModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoinThumbnail(latitude: coin.lat, longitude: coin.lon)
            VStack(alignment: .leading, spacing: 4) {
                Text(coin.name).font(.headline)
                if species.isEmpty {
                    HStack(spacing: 6) {
                        ScoreDot(value: score?.score, model: model, size: 10)
                        Text(stateText)
                    }
                    .font(.subheadline)
                } else {
                    ForEach(species) { item in
                        HStack(spacing: 6) {
                            ScoreDot(value: item.value, model: model, size: 10)
                            Text(model.speciesName(item.id))
                            Text(model.classify(item.value)?.fr ?? "").foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Les espèces à nommer : celles qui valent au moins « moyen » aujourd'hui.
    private var species: [CoinSpeciesScore] {
        guard let score, let min = model.mediumThreshold else { return [] }
        return CoinTrend.worthSpecies(score, min: min)
    }

    /// Libellé du coin quand aucune espèce n'est nommée : « Faible », « Très faible ».
    private var stateText: String {
        guard let value = score?.score, let threshold = model.classify(value) else {
            return "Pas de météo aujourd'hui"
        }
        return threshold.fr
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

/// Fiche d'un coin poussée dans la pile de Mes coins (18 nov. 2026) : la même `PointSheet` que par
/// son épingle sur la carte, sans feuille. Elle lit l'endroit du coin à l'ouverture
/// (`MapModel.openCoin`), montre une roue en attendant, et rend la sélection au retour. La pile
/// revient à la liste quand la fiche n'est plus celle de ce coin (supprimé, « Voir sur la carte »).
struct CoinPointView: View {
    let coinID: UUID
    let model: MapModel
    @Environment(\.dismiss) private var dismiss
    /// La vue a rendu elle-même la sélection en disparaissant (retour, changement d'onglet) : ce
    /// n'est pas une raison de quitter la pile.
    @State private var releasedOnDisappear = false

    private var coin: Coin? { model.field.coins.first { $0.id == coinID } }

    /// La fiche ouverte dans le modèle est bien celle de ce coin, depuis Mes coins.
    private var isCurrent: Bool {
        model.pointOrigin == .coins && model.pointCoinID == coinID
    }

    var body: some View {
        Group {
            if isCurrent, let info = model.pointInfo {
                PointSheet(info: info, model: model, pushed: true)
            } else {
                ProgressView()
                    .navigationTitle(coin?.name ?? "Coin")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
            }
        }
        .onAppear {
            releasedOnDisappear = false
            if !isCurrent, let coin {
                model.openCoin(coin)
            }
        }
        .onDisappear {
            // retour à la liste ou autre onglet : la sélection est rendue, sauf si elle a déjà
            // changé de main (« Voir sur la carte »)
            if isCurrent {
                releasedOnDisappear = true
                model.clearSelection()
            }
        }
        .onChange(of: model.pointCoinID) { _, id in
            if id != coinID, !releasedOnDisappear {
                dismiss()
            }
        }
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
                "Ajoutez vos coins depuis la carte : touchez un endroit, puis l'étoile de sa fiche. " +
                "Ils restent sur cet appareil et sur le serveur sous un identifiant pseudonyme, jamais partagés."
            )
        } actions: {
            Button("Ouvrir la carte", action: openMap)
                .buttonStyle(.borderedProminent)
        }
    }
}
