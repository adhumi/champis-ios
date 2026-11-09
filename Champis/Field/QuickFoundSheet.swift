import SwiftUI

/// « Trouvé ici » en deux tapes (refonte UX, lot 3, décision du 1er nov. 2026) : l'espèce du
/// calque préremplie et modifiable, la position du point, la date du jour, et trois boutons de
/// quantité. Toucher une quantité enregistre et ferme. C'est, avec « Rien trouvé ici », la seule
/// façon de noter : depuis le point touché sur la carte (9 nov. 2026, plus de « Noter » à ma
/// position ni de formulaire complet).
struct QuickFoundSheet: View {
    nonisolated struct Quantity: Identifiable, Sendable {
        let value: Int
        let label: String
        var id: Int { value }
    }

    static let quantities = [
        Quantity(value: 1, label: "Quelques-uns"),
        Quantity(value: 2, label: "Un bon panier"),
        Quantity(value: 3, label: "Beaucoup"),
    ]

    let model: MapModel
    let point: MapSelection
    @State private var speciesID: String
    @Environment(\.dismiss) private var dismiss

    init(model: MapModel, point: MapSelection, initialSpecies: String?) {
        self.model = model
        self.point = point
        _speciesID = State(initialValue: initialSpecies ?? model.layerSpecies.first ?? model.speciesOptions.first?.id ?? "")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Espèce", selection: $speciesID) {
                        ForEach(model.speciesOptions) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    LabeledContent("Où", value: Self.coordinates(point.latitude, point.longitude))
                    LabeledContent("Quand", value: "aujourd'hui")
                }
                Section {
                    ForEach(Self.quantities) { quantity in
                        Button {
                            record(quantity.value)
                        } label: {
                            Label(quantity.label, systemImage: "checkmark.circle")
                        }
                        .disabled(speciesID.isEmpty)
                    }
                } header: {
                    Text("Combien ?")
                } footer: {
                    Text("Position et date restent privées : elles servent seulement à calibrer le modèle.")
                }
            }
            .navigationTitle("Trouvé ici")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func record(_ quantity: Int) {
        let field = model.field
        let payload = (speciesID, point.latitude, point.longitude, FieldModel.isoDay(), quantity)
        Task {
            await field.record(
                species: payload.0, latitude: payload.1, longitude: payload.2, accuracyM: nil,
                date: payload.3, found: true, quantity: payload.4
            )
        }
        dismiss()
    }

    /// `47.12345, 6.12345` : le point touché, cinq décimales (environ un mètre).
    static func coordinates(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }
}
