import SwiftUI

/// Écran « Hors ligne » : départements embarqués (taille, dates, état), météo seule à rafraîchir,
/// suppression ; ajout d'un département depuis le manifeste des tuiles.
struct OfflineView: View {
    let offline: OfflineModel
    let model: MapModel
    @State private var showDownload = false

    var body: some View {
        List {
            if offline.departments.isEmpty {
                Text("Aucun département embarqué. En forêt, sans réseau, seules les tuiles déjà vues restent lisibles.")
                    .foregroundStyle(.secondary)
            }
            ForEach(offline.departments) { department in
                OfflineDepartmentRow(department: department, progress: offline.progress[department.code], model: model)
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await offline.delete(code: department.code) }
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                        if department.filesDone {
                            Button {
                                Task { await offline.refreshWeather(code: department.code) }
                            } label: {
                                Label("Météo", systemImage: "cloud.sun")
                            }
                        }
                    }
            }
            Section {
                Button {
                    showDownload = true
                } label: {
                    Label("Ajouter un département", systemImage: "arrow.down.circle")
                }
                .disabled(model.manifest == nil)
                LabeledContent("Total embarqué", value: offline.totalBytes.formatted(.byteCount(style: .file)))
                if let status = offline.status {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Un département pèse de quelques dizaines à quelques centaines de Mo : préférez le Wi‑Fi. Le fond de carte Apple garde un cache limité et peut manquer hors couverture.")
            }
        }
        .navigationTitle("Hors ligne")
        .sheet(isPresented: $showDownload) {
            DownloadDepartmentView(offline: offline, model: model)
        }
        .task { model.loadBoundariesIfNeeded() }
    }
}

struct OfflineDepartmentRow: View {
    let department: OfflineDepartment
    let progress: OfflineModel.Progress?
    let model: MapModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(department.name.map { "\($0) (\(department.code))" } ?? "Département \(department.code)")
                    .font(.headline)
                Spacer()
                Text(department.bytes.formatted(.byteCount(style: .file))).monospacedDigit()
            }
            Text(department.species.map { model.speciesName($0) }.joined(separator: ", "))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let progress {
                ProgressView(value: progress.fraction)
                Text(progress.fetchingWeather ? "Météo en cours…" : "\(progress.filesDone)/\(progress.filesTotal) fichiers")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if department.complete {
                Text("Météo du \(MapModel.format(iso: department.weatherToday ?? "")) · tuiles du \(department.tilesGenerated.map { MapModel.format(timestamp: $0) } ?? "?")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Label(department.error ?? "Incomplet", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Choix d'un département et des espèces à embarquer, avec le poids estimé.
struct DownloadDepartmentView: View {
    let offline: OfflineModel
    let model: MapModel
    @State private var selectedCode: String?
    @State private var selectedSpecies: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    private var choices: [DownloadableDepartment] {
        guard let manifest = model.manifest else { return [] }
        return OfflineModel.downloadable(from: manifest, names: model.departmentNames)
    }

    private var choice: DownloadableDepartment? {
        choices.first { $0.code == selectedCode }
    }

    var body: some View {
        NavigationStack {
            Form {
                if choices.isEmpty {
                    Text("Le serveur ne publie pas encore de jeux par département.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Département", selection: $selectedCode) {
                        Text("Choisir…").tag(Optional<String>.none)
                        ForEach(choices) { choice in
                            Text(choice.title).tag(Optional(choice.code))
                        }
                    }
                    if let choice {
                        Section("Espèces") {
                            ForEach(choice.species, id: \.self) { sid in
                                Toggle(model.speciesName(sid), isOn: Binding(
                                    get: { selectedSpecies.contains(sid) },
                                    set: { on in
                                        if on { selectedSpecies.insert(sid) } else { selectedSpecies.remove(sid) }
                                    }
                                ))
                            }
                            LabeledContent("Poids estimé", value: choice.bytes(for: Array(selectedSpecies)).formatted(.byteCount(style: .file)))
                            if choice.altitude == nil {
                                Text("Pas de couche d'altitude pour ce département : classe prise sur la médiane de la cellule.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Ajouter un département")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Télécharger") {
                        guard let choice, let manifest = model.manifest else { return }
                        let species = Array(selectedSpecies)
                        let version = model.catalog?.scoringVersion ?? ""
                        Task { await offline.download(choice, species: species, manifest: manifest, scoringVersion: version) }
                        dismiss()
                    }
                    .disabled(choice == nil || selectedSpecies.isEmpty)
                }
            }
            .onChange(of: selectedCode) { _, _ in
                selectedSpecies = Set(choice?.species ?? [])
            }
        }
    }
}
