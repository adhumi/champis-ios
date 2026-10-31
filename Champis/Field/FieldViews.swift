import ChampisScoring
import SwiftUI

/// Espèce proposée dans un sélecteur.
nonisolated struct SpeciesOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

/// Ouverture du formulaire d'observation, préremplie depuis la carte ou la fiche.
nonisolated struct ObservationFormRequest: Identifiable, Sendable {
    let id = UUID()
    let found: Bool
    let species: String?
    let point: MapSelection?
}

/// Saisie d'une observation : « trouvé » et « rien trouvé » sont à égalité, les négatives valent
/// autant que les positives. Pas de photo, pas de commentaire, pas de nom de lieu.
struct ObservationForm: View {
    let field: FieldModel
    let species: [SpeciesOption]
    @State private var speciesID: String
    @State private var found: Bool
    @State private var quantity = 2
    @State private var date = Date()
    @State private var latitude: Double?
    @State private var longitude: Double?
    @State private var accuracy: Double?
    @State private var locating = false
    @State private var locationError: String?
    @Environment(\.dismiss) private var dismiss

    init(field: FieldModel, species: [SpeciesOption], initialSpecies: String?, at point: MapSelection?, found: Bool) {
        self.field = field
        self.species = species
        _speciesID = State(initialValue: initialSpecies ?? species.first?.id ?? "")
        _found = State(initialValue: found)
        _latitude = State(initialValue: point?.latitude)
        _longitude = State(initialValue: point?.longitude)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Espèce", selection: $speciesID) {
                        ForEach(species) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    Picker("Résultat", selection: $found) {
                        Text("Trouvé").tag(true)
                        Text("Rien trouvé").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if found {
                        Picker("Quantité", selection: $quantity) {
                            Text("Quelques-uns").tag(1)
                            Text("Un bon panier").tag(2)
                            Text("Beaucoup").tag(3)
                        }
                    }
                    DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
                }
                Section {
                    if let latitude, let longitude {
                        LabeledContent("Position", value: Self.coordinates(latitude, longitude, accuracy))
                    } else {
                        Text("Aucune position : utilisez la vôtre, ou touchez la carte avant d'ouvrir ce formulaire.")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await locate() }
                    } label: {
                        Label(locating ? "Recherche de la position…" : "Utiliser ma position", systemImage: "location")
                    }
                    .disabled(locating)
                    if let locationError {
                        Text(locationError).foregroundStyle(.red)
                    }
                } footer: {
                    Text("Position et date restent privées : elles servent seulement à calibrer le modèle. Rien n'est partagé avec les autres.")
                }
            }
            .navigationTitle(found ? "Trouvé" : "Rien trouvé")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { save() }
                        .disabled(latitude == nil || speciesID.isEmpty)
                }
            }
        }
    }

    private func locate() async {
        locating = true
        locationError = nil
        defer { locating = false }
        do {
            if let fix = try await LocationProvider.currentFix() {
                latitude = fix.latitude
                longitude = fix.longitude
                accuracy = fix.accuracyM
            } else {
                locationError = "Position refusée ou indisponible."
            }
        } catch {
            locationError = error.localizedDescription
        }
    }

    private func save() {
        guard let latitude, let longitude else { return }
        let field = field
        let payload = (speciesID, latitude, longitude, accuracy, FieldModel.isoDay(date), found, found ? quantity : nil)
        Task {
            await field.record(
                species: payload.0, latitude: payload.1, longitude: payload.2, accuracyM: payload.3,
                date: payload.4, found: payload.5, quantity: payload.6
            )
        }
        dismiss()
    }

    static func coordinates(_ latitude: Double, _ longitude: Double, _ accuracy: Double?) -> String {
        var text = String(format: "%.5f, %.5f", latitude, longitude)
        if let accuracy {
            text += " · ±\(Int(accuracy.rounded())) m"
        }
        return text
    }
}

/// Mes coins : score du jour et meilleur jour à venir, calculés par le backend (`GET /coins`).
struct CoinsView: View {
    let field: FieldModel
    let model: MapModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if field.coins.isEmpty {
                    Text("Aucun coin. Touchez un point de la carte, puis « Ajouter à mes coins ».")
                        .foregroundStyle(.secondary)
                }
                ForEach(field.coins) { coin in
                    CoinRow(coin: coin, score: field.coinScores[coin.id], model: model)
                }
                .onDelete { offsets in
                    let ids = offsets.map { field.coins[$0].id }
                    Task {
                        for id in ids {
                            await field.removeCoin(id)
                        }
                    }
                }
                if let status = field.status {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Mes coins")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .task { await field.refreshCoinScores() }
            .refreshable { await field.refreshCoinScores() }
        }
    }
}

struct CoinRow: View {
    let coin: Coin
    let score: ScoredCoin?
    let model: MapModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(coin.name).font(.headline)
                Spacer()
                if let value = score?.score {
                    Text("\(PointSheet.number(value)) · \(model.classify(value)?.fr ?? "")")
                        .monospacedDigit()
                } else {
                    Text("pas de météo").foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(model.layerTitle(forTarget: coin.target))
                if let leading = score?.leading {
                    Text("· \(model.speciesName(leading))")
                }
                Spacer()
                if let bestDay = score?.bestDay, let best = score?.best {
                    Text("mieux \(MapModel.format(iso: bestDay)) : \(PointSheet.number(best))")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
