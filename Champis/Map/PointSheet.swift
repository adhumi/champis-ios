import ChampisScoring
import SwiftUI

/// Fiche du point touché (refonte UX, lot 2, décision du 1er nov. 2026) : le libellé de la palette
/// et le jour en titre, l'espèce mise en avant, les onze jours du point, les trois boutons de
/// terrain, et tous les chiffres derrière « Détails ». Depuis le 17 nov. 2026 (spec › App iOS ›
/// Fiche d'un point, toutes les espèces et une phrase) : une phrase rédigée, terrain compris
/// (libellé de T, puis `GET /weather` › `sentence`), et sous l'espèce mise en avant toutes les
/// autres espèces qui ont du terrain ici, par famille ; toucher une ligne la met en avant sans
/// changer la couche de la carte. La couleur ne porte jamais seule l'information : le libellé est
/// toujours écrit.
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
    @State private var quickFound: MapSelection?
    @State private var namingCoin = false
    @State private var coinName = ""

    var body: some View {
        NavigationStack {
            List {
                if let featured {
                    summarySection(featured)
                } else {
                    switch info.outcome {
                    case .noWeather:
                        Section {
                            Text("Du terrain, mais pas de météo pour ce secteur aujourd'hui : le serveur réessaie.")
                                .foregroundStyle(.secondary)
                            forestRow
                        }
                    default:
                        Text(families.isEmpty ? "Hors forêt ou pas de donnée ici." : "Pas de terrain ici pour l'espèce affichée sur la carte.")
                            .foregroundStyle(.secondary)
                    }
                }
                familySections
                fieldSection
                if let featured {
                    detailsSection(featured)
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // ferme la feuille comme l'inspecteur : c'est la sélection qui commande
                    Button("OK") { model.clearSelection() }
                }
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
        }
        // par point : dans l'inspecteur (iPad, Mac), la fiche reste la même vue d'un point à l'autre
        .task(id: info.id) { await model.loadFactors(for: info) }
        // statut de la forêt (étape B5) : en parallèle de la météo, la fiche ne l'attend pas
        .task(id: info.id) { await model.loadForest(for: info) }
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
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    // MARK: - En clair

    /// Espèce en tête de fiche : celle de la couche, ou celle dont l'utilisateur a touché la ligne.
    private var featured: PointSpecies? { model.featured(for: info) }

    /// Les autres espèces du point, par famille.
    private var families: [PointFamily] { model.pointFamilies(for: info) }

    /// L'espèce mise en avant est celle qui porte le score de la couche : son score est celui de
    /// la carte, interpolé entre cellules.
    private func isLayerLead(_ featured: PointSpecies) -> Bool {
        featured.id == info.scored?.species
    }

    @ViewBuilder
    private func summarySection(_ featured: PointSpecies) -> some View {
        let text = Self.sentence(
            terrain: model.classify(featured.terrain)?.label, mode: info.mode, sentence: model.pointSentence,
            summary: model.pointSummary
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
            forestRow
        }
    }

    /// Les autres espèces qui ont du terrain ici, une section par famille (17 nov. 2026).
    @ViewBuilder
    private var familySections: some View {
        ForEach(families) { family in
            Section {
                ForEach(family.species) { species in
                    Button {
                        model.feature(species.id)
                    } label: {
                        speciesRow(species)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Affiche le détail de cette espèce")
                }
            } header: {
                if let symbol = GroupSymbol.assetName(for: .group(family.id)) {
                    Label {
                        Text(family.title)
                    } icon: {
                        Image(symbol)
                    }
                } else {
                    Text(family.title)
                }
            }
        }
    }

    /// Icône, nom français, nom latin, pastille et libellé de palette : jamais de chiffre ici.
    private func speciesRow(_ species: PointSpecies) -> some View {
        HStack(spacing: 10) {
            SpeciesThumbnail(species: species.id, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.speciesName(species.id))
                let latin = model.speciesLatin(species.id)
                if !latin.isEmpty {
                    Text(latin).font(.subheadline).italic().foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if info.mode == .score, species.value == nil, info.cell != nil, model.pointDetail == nil, model.factorsProblem == nil {
                ProgressView().controlSize(.small)
            } else {
                ScoreDot(value: species.value, model: model)
                Text(scoreLabel(species.value)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
    /// pas), deux-points, puis `sentence` de l'API et un point. Sans `sentence` (API plus ancienne),
    /// le terrain seul et la liste `summary` à la suite (`phrases`). Fonction pure, testée.
    nonisolated static func sentence(
        terrain label: String?, mode: MapMode, sentence: String?, summary: [String]?
    ) -> (sentence: String, phrases: [String]) {
        let phrase = terrainPhrase(label: label)
        let lead = phrase.prefix(1).uppercased() + phrase.dropFirst()
        if mode == .terrain {
            return ("\(lead) : potentiel toute saison, sans la météo.", [])
        }
        if let sentence, !sentence.isEmpty {
            return ("\(lead) : \(sentence).", [])
        }
        return ("\(lead).", summary ?? [])
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
            if info.scored != nil {
                Button {
                    coinName = ""
                    namingCoin = true
                } label: {
                    Label("Ajouter à mes coins", systemImage: "star")
                }
            }
        }
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
        info.scored == nil ? "Point" : (info.mode == .score ? "Score du jour" : "Potentiel")
    }

    @ViewBuilder
    private func detailsSection(_ featured: PointSpecies) -> some View {
        Section("Détails") {
            DisclosureGroup("Chiffres et facteurs") {
                if let value = featured.value {
                    LabeledContent(info.mode == .score ? "Score S" : "Potentiel T", value: Self.number(value))
                }
                LabeledContent("Potentiel terrain T", value: Self.number(featured.terrain))
                // Espèce de la couche : `factor` est interpolé entre les cellules voisines, comme la
                // couleur de la carte ; `M_eff` et `Φ` sont ceux de la cellule qui porte le point
                // (bbox ou GET /weather). Autre espèce : tout vient de la cellule du point.
                let scored = isLayerLead(featured) ? info.scored : nil
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
                    if scored == nil {
                        Text("Pour une espèce qui n'est pas affichée sur la carte, le score est celui de la cellule météo qui porte ce point, sans interpolation avec ses voisines : il peut différer d'un cran de la couleur qu'aurait la carte.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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
