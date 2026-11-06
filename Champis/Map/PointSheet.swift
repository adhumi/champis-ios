import ChampisScoring
import SwiftUI

/// Fiche du point touché (refonte UX, lot 2, décision du 1er nov. 2026) : le libellé de la palette
/// et le jour en titre, l'espèce qui porte le score, des phrases en clair (terrain depuis le libellé
/// de T, météo et saison depuis `GET /weather` › `summary`), les onze jours du point, les trois
/// boutons de terrain, et tous les chiffres derrière « Détails ». La couleur ne porte jamais seule
/// l'information : le libellé est toujours écrit.
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
                switch info.outcome {
                case .noData:
                    Text("Hors forêt ou pas de donnée ici.")
                        .foregroundStyle(.secondary)
                case .noWeather:
                    Section {
                        Text("Du terrain, mais pas de météo pour ce secteur aujourd'hui : le serveur réessaie.")
                            .foregroundStyle(.secondary)
                        forestRow
                    }
                case .scored(let scored):
                    summarySection(scored)
                }
                fieldSection
                if case .scored(let scored) = info.outcome {
                    detailsSection(scored)
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
                QuickFoundSheet(model: model, point: point, initialSpecies: info.scored?.species)
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

    @ViewBuilder
    private func summarySection(_ scored: PointInfo.Scored) -> some View {
        Section {
            HStack(spacing: 8) {
                ScoreDot(value: scored.value, model: model, size: 16)
                Text(headline(scored)).font(.title3).fontWeight(.semibold)
            }
            .accessibilityElement(children: .combine)
            Text(subtitle(scored)).foregroundStyle(.secondary)
            ForEach(phrases(scored), id: \.self) { phrase in
                Text(phrase)
            }
            if info.mode == .score, scored.cell != nil, model.pointSummary == nil, model.factorsStatus == nil,
               model.factorsProblem == nil {
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

    private func headline(_ scored: PointInfo.Scored) -> String {
        let label = model.classify(scored.value)?.fr ?? "Score"
        guard info.mode == .score, let date = info.date, let today = model.today else {
            return "\(label), toute saison"
        }
        return date == today ? "\(label) aujourd'hui" : "\(label) \(CoinTrend.weekdayName(iso: date))"
    }

    private func subtitle(_ scored: PointInfo.Scored) -> String {
        var parts = [model.speciesName(scored.species)]
        if info.mode == .score, let date = info.date {
            parts.append(MapModel.format(iso: date))
        }
        return parts.joined(separator: " · ")
    }

    /// Terrain d'abord (depuis le libellé de T), puis les phrases de l'API ; sans météo, on le dit.
    private func phrases(_ scored: PointInfo.Scored) -> [String] {
        var out = [Self.terrainPhrase(label: model.classify(scored.terrain)?.label)]
        if info.mode == .terrain {
            out.append("potentiel toute saison, sans la météo")
        } else if let summary = model.pointSummary {
            out += summary
        } else if let status = model.factorsStatus {
            out.append(status)
        }
        return out
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
    private func detailsSection(_ scored: PointInfo.Scored) -> some View {
        Section("Détails") {
            DisclosureGroup("Chiffres et facteurs") {
                LabeledContent(info.mode == .score ? "Score S" : "Potentiel T", value: Self.number(scored.value))
                LabeledContent("Potentiel terrain T", value: Self.number(scored.terrain))
                if let row = scored.row ?? model.pointRow {
                    LabeledContent("M_eff × Φ", value: Self.number(row.factor))
                    LabeledContent("Indice météo M_eff", value: Self.number(row.mEff))
                    LabeledContent("Fenêtre Φ", value: Self.number(row.phi))
                } else if let factor = scored.factor {
                    // champ compact (sous le zoom 9) : le produit seul, le détail arrive par GET /weather
                    LabeledContent("M_eff × Φ", value: Self.number(factor))
                }
                LabeledContent("Classe d'altitude", value: altitudeText(scored))
                if let cell = scored.cell {
                    LabeledContent("Cellule météo", value: cell.id + (scored.stale ? " · météo périmée" : ""))
                }
                if info.mode == .score, scored.cell != nil {
                    if let factors = model.pointFactors {
                        ForEach(Self.factors) { factor in
                            if let value = factors[factor.key] {
                                FactorRow(label: factor.label, value: value)
                            }
                        }
                    }
                    Text("Chaque facteur vaut de 0 à 1. Les facteurs terrain (essence, pH, exposition) ne sont pas dans les tuiles.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func altitudeText(_ scored: PointInfo.Scored) -> String {
        let classM = Int(model.palette?.altEncoding.classM ?? 300)
        if let k = scored.altClass {
            return "\(k * classM)–\((k + 1) * classM) m"
        }
        if let key = scored.altKey, scored.altFallback {
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
