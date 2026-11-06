import SwiftUI

/// « Noter » à ma position (étape B4, 6 nov. 2026, audit U7) : trouvé et rien trouvé dans la même
/// feuille, préremplie à la position GPS du moment (précision affichée), avec l'espèce du calque et
/// la date du jour. Toucher une quantité enregistre et ferme ; « Rien trouvé » note une négative par
/// espèce de la couche, annulable cinq secondes depuis la carte.
struct NoteSheet: View {
    let model: MapModel
    let fix: LocationProvider.Fix
    @State private var speciesID: String
    @Environment(\.dismiss) private var dismiss

    init(model: MapModel, fix: LocationProvider.Fix) {
        self.model = model
        self.fix = fix
        _speciesID = State(initialValue: model.layerSpecies.first ?? model.speciesOptions.first?.id ?? "")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Où", value: "ma position · " + ObservationForm.coordinates(fix.latitude, fix.longitude, fix.accuracyM))
                    LabeledContent("Quand", value: "aujourd'hui")
                } footer: {
                    Text("Position et date restent privées : elles servent seulement à calibrer le modèle.")
                }
                Section {
                    Picker("Espèce", selection: $speciesID) {
                        ForEach(model.speciesOptions) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    ForEach(QuickFoundSheet.quantities) { quantity in
                        Button {
                            recordFound(quantity.value)
                        } label: {
                            Label(quantity.label, systemImage: "checkmark.circle")
                        }
                        .disabled(speciesID.isEmpty)
                    }
                } header: {
                    Text("Trouvé")
                }
                Section {
                    Button {
                        recordNotFound()
                    } label: {
                        Label(notFoundLabel, systemImage: "xmark.circle")
                    }
                    .disabled(notFoundSpecies.isEmpty)
                } header: {
                    Text("Rien trouvé")
                } footer: {
                    Text("Une observation par espèce de la couche ; « Annuler » reste proposé cinq secondes sur la carte.")
                }
            }
            .navigationTitle("Noter ici")
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

    /// Les espèces de la couche, à défaut celle choisie : une négative par espèce.
    private var notFoundSpecies: [String] {
        let layer = model.layerSpecies
        if !layer.isEmpty { return layer }
        return speciesID.isEmpty ? [] : [speciesID]
    }

    private var notFoundLabel: String {
        if let title = model.selectedLayer?.title, !model.layerSpecies.isEmpty {
            return "Rien trouvé : \(title.lowercased())"
        }
        return "Rien trouvé"
    }

    private func recordFound(_ quantity: Int) {
        let field = model.field
        let fix = fix
        let species = speciesID
        let day = FieldModel.isoDay()
        Task {
            await field.record(
                species: species, latitude: fix.latitude, longitude: fix.longitude, accuracyM: fix.accuracyM,
                date: day, found: true, quantity: quantity
            )
        }
        dismiss()
    }

    private func recordNotFound() {
        let field = model.field
        let fix = fix
        let species = notFoundSpecies
        Task {
            await field.recordNotFound(species: species, latitude: fix.latitude, longitude: fix.longitude, accuracyM: fix.accuracyM)
        }
        dismiss()
    }
}
