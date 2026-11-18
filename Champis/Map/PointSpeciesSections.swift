import SwiftUI

/// Les espèces qui ont du terrain à un endroit, une section par famille (spec › App iOS › Fiche
/// d'un point et fiche d'un coin, une seule vue, 18 nov. 2026) : aquarelle, nom français, nom
/// latin, pastille et libellé de palette du score du jour, jamais de chiffre. Toucher une ligne la
/// déplie sur la phrase et la tendance de l'espèce ; une seule ligne ouverte à la fois. Partagé par
/// la fiche d'un point (`PointSheet`) et celle d'un coin (`CoinDetailView`).
struct PointSpeciesSections: View {
    let families: [PointFamily]
    let model: MapModel
    /// La météo des espèces n'est pas encore arrivée : une roue à la place du libellé.
    let pending: Bool
    /// Espèce dont la ligne est dépliée.
    @Binding var expanded: String?
    /// Phrase et tendance d'une espèce ; `nil` tant qu'elles ne sont pas connues.
    let expansion: (PointSpecies) -> PointExpansion?

    var body: some View {
        ForEach(families) { family in
            Section {
                ForEach(family.species) { species in
                    row(species)
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

    private func row(_ species: PointSpecies) -> some View {
        let isExpanded = expanded == species.id
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation {
                    expanded = isExpanded ? nil : species.id
                }
            } label: {
                header(species, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "déplié" : "replié")
            .accessibilityHint("Affiche la phrase et la tendance de cette espèce")
            if isExpanded {
                detail(species)
            }
        }
    }

    private func header(_ species: PointSpecies, isExpanded: Bool) -> some View {
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
            if species.value == nil, pending {
                ProgressView().controlSize(.small)
            } else {
                ScoreDot(value: species.value, model: model)
                Text(label(species.value)).font(.subheadline).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.down")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func detail(_ species: PointSpecies) -> some View {
        if let content = expansion(species) {
            Text(content.sentence).font(.subheadline)
            ForEach(content.phrases, id: \.self) { phrase in
                Text(phrase).font(.subheadline)
            }
            if let trend = content.trend {
                Text("Tendance : \(trend)").font(.subheadline).fontWeight(.semibold)
            }
        } else if pending {
            ProgressView().controlSize(.small)
        } else {
            Text("Pas de météo pour cette espèce ici.").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    /// Libellé de palette d'une valeur ; sans météo pour l'espèce, on le dit.
    private func label(_ value: Double?) -> String {
        guard let value else { return "Sans météo" }
        return model.classify(value)?.fr ?? "Score"
    }
}
