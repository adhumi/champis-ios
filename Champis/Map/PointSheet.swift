import ChampisScoring
import Foundation
import SwiftUI

/// Fiche du point touché (refonte UX, lot 2, décision du 1er nov. 2026) : le libellé de la palette
/// et le jour en titre, l'espèce mise en avant, les onze jours du point, les trois boutons de
/// terrain, et tous les chiffres derrière « Détails ». Depuis le 17 nov. 2026 (spec › App iOS ›
/// Fiche d'un point, toutes les espèces et une phrase) : une phrase rédigée, terrain compris
/// (libellé de T, puis `GET /weather` › `sentence`), et sous l'espèce en exergue toutes les autres
/// espèces qui ont du terrain ici, par famille. Depuis le 18 nov. 2026 (Fiche d'un point et fiche
/// d'un coin, une seule vue) : la fiche se ferme par une croix à gauche de la barre ; à droite, une
/// étoile ajoute le point à mes coins (vide) ou retire le coin (pleine, après confirmation) ;
/// toucher une autre espèce déplie sa ligne (phrase et tendance, `PointSpeciesSections`) sans
/// changer l'espèce en exergue ; pour un coin, ouverte par son épingle ou depuis Mes coins (la
/// même fiche, `MapModel.openCoin`, poussée dans la pile de Mes coins : `pushed`), elle porte son
/// nom, Itinéraire, Renommer et Supprimer. La couleur ne porte jamais seule l'information : le libellé est toujours écrit.
struct PointSheet: View {
    nonisolated struct Factor: Identifiable, Sendable {
        let key: String
        let label: String
        var id: String { key }
    }

    static let factors = [
        Factor(key: "temp", label: "Température"),
        Factor(key: "rain", label: "Pluie"),
        Factor(key: "trigger", label: "Pluie déclenchante"),
        Factor(key: "soil_moisture", label: "Humidité du sol"),
        Factor(key: "frost", label: "Gel"),
        Factor(key: "water_balance", label: "Bilan hydrique"),
        Factor(key: "heat", label: "Chaleur"),
        Factor(key: "memory", label: "Mémoire"),
    ]

    let info: PointInfo
    let model: MapModel
    /// Poussée dans la pile de navigation de Mes coins (18 nov. 2026) : la fiche n'a alors ni sa
    /// propre pile ni sa croix, le retour de la pile la ferme. En feuille ou dans l'inspecteur
    /// (carte, iPad, Mac) : `false`.
    var pushed = false
    @State private var quickFound: MapSelection?
    @State private var namingCoin = false
    @State private var coinName = ""
    /// Espèce dont la ligne est dépliée ; une seule à la fois.
    @State private var expanded: String?
    @State private var renamingCoin = false
    @State private var confirmDeleteCoin = false

    var body: some View {
        if pushed {
            content
        } else {
            NavigationStack {
                content
            }
            #if os(iOS)
            .presentationDetents([.medium, .large])
            #endif
        }
    }

    private var content: some View {
        List {
                // statut de la forêt : sa propre section, en tête de fiche (18 nov. 2026)
                if model.pointForest != nil {
                    Section {
                        forestRow
                            // vert forêt clair : la couleur d'accent de l'app, assez légère pour
                            // que le texte reste lisible en clair comme en sombre
                            .listRowBackground(Color.accentColor.opacity(0.16))
                    }
                }
                if let featured {
                    summarySection(featured)
                } else {
                    switch info.outcome {
                    case .noWeather:
                        Section {
                            Text("Du terrain, mais pas de météo pour ce secteur aujourd'hui : le serveur réessaie.")
                                .foregroundStyle(.secondary)
                        }
                    default:
                        Text(families.isEmpty ? "Hors forêt ou pas de donnée ici." : "Pas de terrain ici pour l'espèce affichée sur la carte.")
                            .foregroundStyle(.secondary)
                    }
                }
                PointSpeciesSections(families: families, model: model, pending: isLoadingWeather, expanded: $expanded) { species in
                    model.expansion(for: species, info: info)
                }
                fieldSection
                if let featured {
                    detailsSection(featured)
                }
                if coin != nil {
                    coinSection
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if !pushed {
                    ToolbarItem(placement: .cancellationAction) {
                        // ferme la feuille comme l'inspecteur : c'est la sélection qui commande
                        Button {
                            model.clearSelection()
                        } label: {
                            Label("Fermer", systemImage: "xmark")
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    starButton
                }
            }
            .alert("Nom du coin", isPresented: $renamingCoin) {
                TextField("Nom", text: $coinName)
                Button("Enregistrer") { renameCoin() }
                Button("Annuler", role: .cancel) {}
            }
            .confirmationDialog("Supprimer ce coin ?", isPresented: $confirmDeleteCoin, titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) { removeCoin() }
            } message: {
                Text("Le coin est retiré de l'appareil et du serveur.")
            }
            .sheet(item: $quickFound) { point in
                QuickFoundSheet(model: model, point: point, initialSpecies: featured?.id ?? info.scored?.species)
            }
            .alert("Nom du coin", isPresented: $namingCoin) {
                TextField("Nom", text: $coinName)
                Button("Ajouter") { addCoin() }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Le coin reste privé. Une notification viendra quand son score sera bon ou excellent.")
            }
        // par point : dans l'inspecteur (iPad, Mac), la fiche reste la même vue d'un point à l'autre
        .task(id: info.id) { await model.loadFactors(for: info) }
        // statut de la forêt (étape B5) : en parallèle de la météo, la fiche ne l'attend pas
        .task(id: info.id) { await model.loadForest(for: info) }
        // dans l'inspecteur (iPad, Mac) la vue reste d'un point à l'autre : rien ne reste déplié
        .onChange(of: info.id) { expanded = nil }
        .onAppear {
            // appui long › « Ajouter à mes coins » : la fiche s'ouvre déjà sur le nom
            if model.coinRequestFromLongPress {
                model.clearCoinRequest()
                if info.scored != nil {
                    coinName = ""
                    namingCoin = true
                }
            }
        }
    }

    // MARK: - En clair

    /// Espèce en tête de fiche : celle qui porte le score de la couche.
    private var featured: PointSpecies? { model.featured(for: info) }

    /// Les autres espèces du point, par famille.
    private var families: [PointFamily] { model.pointFamilies(for: info) }

    /// La météo des espèces du point est demandée et n'est pas encore arrivée.
    private var isLoadingWeather: Bool {
        guard info.mode == .score, info.cell != nil else { return false }
        if model.pointDetail != nil { return false }
        return model.factorsProblem == nil
    }

    @ViewBuilder
    private func summarySection(_ featured: PointSpecies) -> some View {
        let text = Self.sentence(
            terrain: model.classify(featured.terrain)?.label, mode: info.mode, sentence: model.pointSentence,
            tone: model.pointSentenceTone, summary: model.pointSummary
        )
        Section {
            HStack(spacing: 10) {
                SpeciesThumbnail(species: featured.id, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        ScoreDot(value: featured.value, model: model, size: 16)
                        Text(headline(featured)).font(.title3).fontWeight(.semibold)
                    }
                    Text(subtitle(featured)).foregroundStyle(.secondary)
                    let latin = model.speciesLatin(featured.id)
                    if !latin.isEmpty {
                        Text(latin).font(.subheadline).italic().foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            Text(text.sentence)
            // API plus ancienne, sans `sentence` : la liste de phrases d'avant
            ForEach(text.phrases, id: \.self) { phrase in
                Text(phrase)
            }
            if info.mode == .score, model.pointSentence == nil, model.pointSummary == nil, let status = model.factorsStatus {
                Text(status).foregroundStyle(.secondary)
            }
            if info.mode == .score, info.cell != nil, model.pointDetail == nil, model.factorsProblem == nil {
                ProgressView().controlSize(.small)
            }
            if info.mode == .score, let problem = model.factorsProblem {
                ProblemView(problem: problem) {
                    let model = model
                    let info = info
                    Task { await model.loadFactors(for: info) }
                }
            }
            if info.mode == .score, !model.pointDays.isEmpty, let today = model.today {
                // en lecture seule : la carte montre toujours aujourd'hui (étape A, 6 nov. 2026)
                CoinDaysView(days: model.pointDays, today: today, selected: .constant(today), model: model, interactive: false)
                    .padding(.vertical, 4)
                // tendance et meilleur jour (étape B2), même règle que les coins
                if let trend = trendPhrase(today: today) {
                    Text("Tendance : \(trend)").fontWeight(.semibold)
                }
            }
        }
    }

    /// Libellé de palette d'une valeur ; sans météo pour l'espèce, on le dit.
    private func scoreLabel(_ value: Double?) -> String {
        guard let value else { return "Sans météo" }
        return model.classify(value)?.fr ?? "Score"
    }

    private func trendPhrase(today: String) -> String? {
        guard let goodMin = model.goodThreshold else { return nil }
        return CoinTrend.phrase(CoinTrend.kind(days: model.pointDays, today: today, goodMin: goodMin))
    }

    /// Forêt domaniale, autre forêt publique, ou sans doute privée (étape B5) ; rien hors ligne.
    @ViewBuilder
    private var forestRow: some View {
        if let forest = model.pointForest {
            Label(forest, systemImage: "tree")
                .font(.subheadline)
        }
    }

    private func headline(_ featured: PointSpecies) -> String {
        let label = scoreLabel(featured.value)
        guard info.mode == .score, let date = info.date, let today = model.today else {
            return "\(label), toute saison"
        }
        return date == today ? "\(label) aujourd'hui" : "\(label) \(CoinTrend.weekdayName(iso: date))"
    }

    private func subtitle(_ featured: PointSpecies) -> String {
        var parts = [model.speciesName(featured.id)]
        if info.mode == .score, let date = info.date {
            parts.append(MapModel.format(iso: date))
        }
        return parts.joined(separator: " · ")
    }

    /// La phrase de la fiche : le terrain (depuis le libellé de palette de `T`, que l'API ne connaît
    /// pas), une liaison (`link`), puis `sentence` de l'API et un point. Sans `sentence` (API plus
    /// ancienne), le terrain seul et la liste `summary` à la suite (`phrases`). Fonction pure, testée.
    nonisolated static func sentence(
        terrain label: String?, mode: MapMode, sentence: String?, tone: String? = nil, summary: [String]?
    ) -> (sentence: String, phrases: [String]) {
        let phrase = terrainPhrase(label: label)
        let lead = phrase.prefix(1).uppercased() + phrase.dropFirst()
        if mode == .terrain {
            return ("\(lead) : potentiel toute saison, sans la météo.", [])
        }
        if let sentence, !sentence.isEmpty {
            return ("\(lead)\(link(terrain: label, tone: tone))\(sentence).", [])
        }
        return ("\(lead).", summary ?? [])
    }

    /// Ce qui relie le terrain à la phrase (spec › App iOS › Liaison entre le terrain et la phrase,
    /// 18 nov. 2026) : « et » quand la suite va dans le même sens que le terrain, « mais » quand
    /// elle s'y oppose, une virgule quand l'un des deux est neutre ; les deux-points d'avant sans
    /// `sentence_tone` (réponse plus ancienne). Le sens du terrain vient de son libellé de palette.
    nonisolated static func link(terrain label: String?, tone: String?) -> String {
        let weather: Bool?
        switch tone {
        case "favorable": weather = true
        case "defavorable": weather = false
        case "neutre": weather = nil
        default: return " : "
        }
        let terrain: Bool?
        switch label {
        case "excellent", "bon": terrain = true
        case "moyen", nil: terrain = nil
        default: terrain = false
        }
        guard let weather, let terrain else { return ", " }
        return weather == terrain ? " et " : " mais "
    }

    /// Phrase de terrain depuis le libellé de palette de `T` : l'API ne connaît pas le pixel.
    nonisolated static func terrainPhrase(label: String?) -> String {
        switch label {
        case "excellent": "terrain très favorable"
        case "bon": "terrain favorable"
        case "moyen": "terrain moyen"
        case nil: "terrain inconnu"
        default: "terrain peu favorable"
        }
    }

    // MARK: - Retour terrain

    /// Deux tapes en forêt (lot 3) : « Rien trouvé ici » enregistre tout de suite (annulable cinq
    /// secondes depuis la carte), « Trouvé ici » ne demande que la quantité. Un coin garde la cible
    /// de la couche, la classe d'altitude et le T de chaque espèce du pixel.
    private var fieldSection: some View {
        Section {
            Button {
                quickFound = point
            } label: {
                Label("Trouvé ici", systemImage: "checkmark.circle")
            }
            Button {
                let field = model.field
                let species = notFoundSpecies
                let location = point
                model.clearSelection()
                Task { await field.recordNotFound(species: species, latitude: location.latitude, longitude: location.longitude) }
            } label: {
                Label("Rien trouvé ici", systemImage: "xmark.circle")
            }
            .disabled(notFoundSpecies.isEmpty)
        }
    }

    // MARK: - Coin

    /// Le coin dont l'épingle a ouvert la fiche, tant qu'il existe.
    private var coin: Coin? { model.pointCoin }

    /// Étoile de la barre : vide, elle ajoute le point à mes coins (le nom est demandé) ; pleine, le
    /// point est un coin et elle le retire après confirmation.
    private var starButton: some View {
        Button {
            if coin != nil {
                confirmDeleteCoin = true
            } else {
                coinName = ""
                namingCoin = true
            }
        } label: {
            Label(coin != nil ? "Retirer de mes coins" : "Ajouter à mes coins", systemImage: coin != nil ? "star.fill" : "star")
        }
        .disabled(!canToggleCoin)
    }

    /// L'étoile agit : il y a un coin à retirer, ou un point noté à ajouter.
    private var canToggleCoin: Bool {
        if coin != nil { return true }
        return info.scored != nil
    }

    /// Actions d'un coin : Itinéraire, Voir sur la carte quand la fiche vient de Mes coins, Renommer
    /// et Supprimer.
    @ViewBuilder
    private var coinSection: some View {
        Section {
            if model.pointOrigin == .coins {
                Button {
                    showOnMap()
                } label: {
                    Label("Voir sur la carte", systemImage: "map")
                }
            }
            if let directions = Self.directionsURL(latitude: info.latitude, longitude: info.longitude) {
                Link(destination: directions) {
                    Label("Itinéraire", systemImage: "arrow.triangle.turn.up.right.diamond")
                }
            }
        }
        Section {
            Button("Renommer") {
                coinName = coin?.name ?? ""
                renamingCoin = true
            }
            Button("Supprimer", role: .destructive) { confirmDeleteCoin = true }
        }
    }

    private func renameCoin() {
        guard let id = coin?.id else { return }
        let name = coinName
        let field = model.field
        Task { await field.renameCoin(id, to: name) }
    }

    /// Retire le coin. Sur la carte, la fiche reste ouverte sur le point, étoile vide ; ouverte
    /// depuis Mes coins, elle se ferme avec lui.
    private func removeCoin() {
        guard let id = coin?.id else { return }
        let field = model.field
        if model.pointOrigin == .coins {
            model.clearSelection()
        }
        Task { await field.removeCoin(id) }
    }

    /// Ferme la fiche et montre l'endroit du coin sur la carte.
    private func showOnMap() {
        model.clearSelection()
        model.focus(latitude: info.latitude, longitude: info.longitude)
        AppRouter.shared.tab = .map
    }

    /// Itinéraire vers le coin dans Plans (étape B2) : la destination seule, Plans choisit le trajet.
    nonisolated static func directionsURL(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "daddr", value: String(format: "%.6f,%.6f", latitude, longitude))]
        return components?.url
    }

    private var point: MapSelection {
        MapSelection(latitude: info.latitude, longitude: info.longitude)
    }

    /// Les espèces du calque, à défaut celle de la fiche : une négative par espèce.
    private var notFoundSpecies: [String] {
        let layer = model.layerSpecies
        if !layer.isEmpty { return layer }
        return info.scored.map { [$0.species] } ?? []
    }

    private func addCoin() {
        let name = coinName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let model = model
        let info = info
        Task { await model.addCoin(named: name, from: info) }
    }

    // MARK: - Détails

    private var title: String {
        if let coin { return coin.name }
        return info.scored == nil ? "Point" : (info.mode == .score ? "Score du jour" : "Potentiel")
    }

    @ViewBuilder
    private func detailsSection(_ featured: PointSpecies) -> some View {
        Section("Détails") {
            DisclosureGroup("Chiffres et facteurs") {
                if let value = featured.value {
                    LabeledContent(info.mode == .score ? "Score S" : "Potentiel T", value: Self.number(value))
                }
                LabeledContent("Potentiel terrain T", value: Self.number(featured.terrain))
                // `factor` est interpolé entre les cellules voisines, comme la couleur de la carte ;
                // `M_eff` et `Φ` sont ceux de la cellule qui porte le point (bbox ou GET /weather).
                let scored = info.scored
                let row = scored?.row ?? model.pointRow
                if let factor = scored?.factor ?? row?.factor {
                    LabeledContent("M_eff × Φ", value: Self.number(factor))
                }
                if let row {
                    LabeledContent("Indice météo M_eff", value: Self.number(row.mEff))
                    LabeledContent("Fenêtre Φ", value: Self.number(row.phi))
                }
                LabeledContent("Classe d'altitude", value: altitudeText)
                if let cell = info.cell {
                    LabeledContent("Cellule météo", value: cell.id + (info.stale ? " · météo périmée" : ""))
                }
                if info.mode == .score, info.cell != nil {
                    if let factors = model.pointFactors {
                        ForEach(Self.factors) { factor in
                            if let value = factors[factor.key] {
                                FactorRow(label: factor.label, value: value)
                            }
                        }
                    }
                    if scored?.interpolated == true {
                        Text("Le score est interpolé entre les cellules météo voisines. M_eff, Φ et les facteurs sont ceux de la cellule qui porte ce point.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("Pour les espèces de la liste qui ne sont pas affichées sur la carte, le score est celui de la cellule météo qui porte ce point, sans interpolation avec ses voisines : il peut différer d'un cran de la couleur qu'aurait la carte.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Chaque facteur vaut de 0 à 1. Les facteurs terrain (essence, pH, exposition) ne sont pas dans les tuiles.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var altitudeText: String {
        if let altitude = info.altitudeM {
            return "\(Int(altitude)) m"
        }
        let classM = Int(model.palette?.altEncoding.classM ?? 300)
        if let k = info.altClass {
            return "\(k * classM)–\((k + 1) * classM) m"
        }
        if let key = info.altKey, info.altFallback {
            return "\(key) m (médiane cellule)"
        }
        return "inconnue"
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }
}

struct FactorRow: View {
    let label: String
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(PointSheet.number(value)).monospacedDigit()
            }
            ProgressView(value: min(max(value, 0), 1))
        }
        .accessibilityElement(children: .combine)
    }
}
