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
    @Environment(\.dismiss) private var dismiss
    @State private var observationRequest: ObservationFormRequest?
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
                    Text("Du terrain, mais pas de météo pour ce secteur aujourd'hui : le serveur réessaie.")
                        .foregroundStyle(.secondary)
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
                    Button("OK") { dismiss() }
                }
            }
            .sheet(item: $observationRequest) { request in
                ObservationForm(
                    field: model.field, species: model.speciesOptions, initialSpecies: request.species,
                    at: request.point, found: request.found
                )
            }
            .alert("Nom du coin", isPresented: $namingCoin) {
                TextField("Nom", text: $coinName)
                Button("Ajouter") { addCoin() }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Le coin reste privé. Une notification viendra quand son score sera bon ou excellent.")
            }
        }
        .task { await model.loadFactors(for: info) }
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
            if info.mode == .score, scored.cell != nil, model.pointSummary == nil, model.factorsStatus == nil {
                ProgressView().controlSize(.small)
            }
            if info.mode == .score, !model.pointDays.isEmpty, let today = model.today {
                CoinDaysView(days: model.pointDays, today: today, selected: dayBinding, model: model)
                    .padding(.vertical, 4)
            }
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

    /// Choisir un jour dans la fiche change le jour de la carte : la fiche suit.
    private var dayBinding: Binding<String> {
        Binding(
            get: { info.date ?? model.today ?? "" },
            set: { iso in
                if let today = model.today, let t = try? CivilDate(iso: today), let d = try? CivilDate(iso: iso) {
                    model.setDay(d.ordinal - t.ordinal)
                    model.select(latitude: info.latitude, longitude: info.longitude)
                }
            }
        )
    }

    // MARK: - Retour terrain

    /// « rien trouvé » aussi accessible que « trouvé » ; un coin garde la cible de la couche, la
    /// classe d'altitude et le T de chaque espèce du pixel.
    private var fieldSection: some View {
        Section {
            Button {
                observationRequest = ObservationFormRequest(found: true, species: info.scored?.species, point: point)
            } label: {
                Label("Trouvé ici", systemImage: "checkmark.circle")
            }
            Button {
                observationRequest = ObservationFormRequest(found: false, species: info.scored?.species, point: point)
            } label: {
                Label("Rien trouvé ici", systemImage: "xmark.circle")
            }
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

    private func addCoin() {
        guard let scored = info.scored else { return }
        let name = coinName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let target = model.selectedLayer.map { MapModel.apiTarget($0.key) } ?? scored.species
        let classM = Int(model.palette?.altEncoding.classM ?? 300)
        let altClass = scored.altClass.map { $0 * classM + classM / 2 } ?? scored.altKey.flatMap { Int($0) } ?? 0
        let terrains = scored.terrains.isEmpty ? [scored.species: scored.terrain] : scored.terrains
        let field = model.field
        let location = point
        Task {
            await field.addCoin(
                name: name, latitude: location.latitude, longitude: location.longitude, target: target,
                altClass: altClass, t: terrains
            )
        }
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
                if let row = scored.row {
                    LabeledContent("M_eff × Φ", value: Self.number(row.factor))
                    LabeledContent("Indice météo M_eff", value: Self.number(row.mEff))
                    LabeledContent("Fenêtre Φ", value: Self.number(row.phi))
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

/// Fiche d'un département en vue France : libellé du jour, espèce qui porte l'indice, couverture
/// météo ; les chiffres derrière « Détails ».
struct DeptSheet: View {
    let info: DeptInfo
    let model: MapModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if info.code == nil {
                    Text("Hors département.").foregroundStyle(.secondary)
                } else if let row = info.row, let value = row.value {
                    Section {
                        HStack(spacing: 8) {
                            ScoreDot(value: value, model: model, size: 16)
                            Text(headline(value)).font(.title3).fontWeight(.semibold)
                        }
                        .accessibilityElement(children: .combine)
                        if let leading = row.leading {
                            Text("\(model.speciesName(leading)) porte l'indice")
                        }
                        Text("Indice du département, pour la forêt entière ; météo connue sur \(Int((row.coverage * 100).rounded())) % de la forêt.")
                    }
                    Section("Détails") {
                        LabeledContent("Indice", value: PointSheet.number(value))
                        if let layer = info.layerTitle {
                            LabeledContent("Couche", value: layer)
                        }
                        if let date = info.date {
                            LabeledContent("Jour", value: MapModel.format(iso: date))
                        }
                        LabeledContent("Couverture météo", value: "\(Int((row.coverage * 100).rounded())) %")
                    }
                } else {
                    Text("Pas d'indice pour ce jour : météo manquante.").foregroundStyle(.secondary)
                }
                if let status = model.deptStatus {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func headline(_ value: Double) -> String {
        let label = model.classify(value)?.fr ?? "Indice"
        guard let date = info.date, let today = model.today else { return label }
        return date == today ? "\(label) aujourd'hui" : "\(label) \(CoinTrend.weekdayName(iso: date))"
    }

    private var title: String {
        guard let code = info.code else { return "Vue France" }
        if let name = info.name {
            return "\(name) (\(code))"
        }
        return "Département \(code)"
    }
}
