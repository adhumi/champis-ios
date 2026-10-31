import ChampisScoring
import SwiftUI

/// Fiche du point touché (v1 réduite, décision du 30 oct. 2026) : score, espèce qui le porte, `T`,
/// `M_eff`, `Φ`, classe d'altitude, cellule météo et facteurs météo via `GET /weather`. La couleur
/// ne porte jamais seule l'information : le libellé de la palette est toujours écrit.
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

    var body: some View {
        NavigationStack {
            List {
                switch info.outcome {
                case .noData:
                    Text("Hors forêt ou pas de donnée à cet endroit.")
                        .foregroundStyle(.secondary)
                case .noWeather:
                    Text("Du terrain, mais pas de météo pour ce point et ce jour.")
                        .foregroundStyle(.secondary)
                case .scored(let scored):
                    scoredSections(scored)
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
        .task { await model.loadFactors(for: info) }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private var title: String {
        guard case .scored(let scored) = info.outcome else { return "Point" }
        let label = model.classify(scored.value)?.fr ?? ""
        let symbol = info.mode == .score ? "S" : "T"
        return "\(symbol) = \(Self.number(scored.value)) · \(label)"
    }

    @ViewBuilder
    private func scoredSections(_ scored: PointInfo.Scored) -> some View {
        Section {
            LabeledContent("Espèce", value: model.speciesName(scored.species))
            if info.mode == .score, let date = info.date {
                LabeledContent("Jour", value: MapModel.format(iso: date))
            }
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
        }
        if info.mode == .score, scored.cell != nil {
            Section {
                if let factors = model.pointFactors {
                    ForEach(Self.factors) { factor in
                        if let value = factors[factor.key] {
                            FactorRow(label: factor.label, value: value)
                        }
                    }
                } else if let status = model.factorsStatus {
                    Text(status).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            } header: {
                Text("Facteurs météo")
            } footer: {
                Text("Chaque facteur vaut de 0 à 1. Les facteurs terrain (essence, pH, exposition) ne sont pas dans les tuiles.")
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

/// Fiche d'un département en vue France : indice du jour, espèce qui le porte, couverture météo.
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
                    LabeledContent("Indice", value: "\(PointSheet.number(value)) · \(model.classify(value)?.fr ?? "")")
                    if let layer = info.layerTitle {
                        LabeledContent("Couche", value: layer)
                    }
                    if let leading = row.leading {
                        LabeledContent("Espèce qui porte le score", value: model.speciesName(leading))
                    }
                    if let date = info.date {
                        LabeledContent("Jour", value: MapModel.format(iso: date))
                    }
                    LabeledContent("Couverture météo", value: "\(Int((row.coverage * 100).rounded())) %")
                } else {
                    Text("Pas d'indice pour ce jour (météo manquante).").foregroundStyle(.secondary)
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

    private var title: String {
        guard let code = info.code else { return "Vue France" }
        if let name = info.name {
            return "\(name) (\(code))"
        }
        return "Département \(code)"
    }
}
