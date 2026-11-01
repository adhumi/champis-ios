import ChampisScoring
import SwiftUI

/// Onglet Carte (refonte UX, lot 2) : overlay colorisé sur fond Apple (ou départements en vue
/// France), menu de calque (groupes, espèces, potentiel toute saison), bandeau des onze jours
/// coloré par le département sous le centre, légende, fiche au toucher en clair. Les coins ont
/// leur onglet (`CoinsScreen`).
struct MapScreen: View {
    static let defaultAPIBaseURL = "https://champis.adhumi.fr"

    /// Modèle partagé par les trois onglets, créé et démarré par `ContentView`.
    let model: MapModel
    @AppStorage("apiBaseURL") private var apiBaseURL = MapScreen.defaultAPIBaseURL
    @AppStorage("legalNoticeAcknowledged") private var legalNoticeAcknowledged = false
    @State private var showSettings = false
    @State private var showLegalNotice = false
    @State private var showLegend = false
    @State private var observationRequest: ObservationFormRequest?

    var body: some View {
        NavigationStack {
            ZStack {
                MapContainer(model: model)
                    .accessibilityLabel("Carte des champignons")
                VStack(spacing: 8) {
                    controls
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        Button {
                            model.locateMe()
                        } label: {
                            Image(systemName: model.locationDenied ? "location.slash" : "location")
                                .padding(10)
                                .background(.regularMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Centrer sur ma position")
                        .accessibilityHint(model.locationDenied ? "Position refusée dans les réglages du système" : "")
                    }
                    panel
                }
                .padding(12)
            }
            .navigationTitle("Champis")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            observationRequest = ObservationFormRequest(found: true, species: nil, point: model.selection)
                        } label: {
                            Label("Trouvé", systemImage: "checkmark.circle")
                        }
                        Button {
                            observationRequest = ObservationFormRequest(found: false, species: nil, point: model.selection)
                        } label: {
                            Label("Rien trouvé", systemImage: "xmark.circle")
                        }
                    } label: {
                        Label("Retour terrain", systemImage: "leaf")
                    }
                    .disabled(model.catalog == nil)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Réglages", systemImage: "slider.horizontal.3")
                    }
                }
            }
        }
        .sheet(item: $observationRequest) { request in
            ObservationForm(
                field: model.field, species: model.speciesOptions, initialSpecies: request.species,
                at: request.point, found: request.found
            )
        }
        .task {
            if !legalNoticeAcknowledged {
                showLegalNotice = true
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model, apiBaseURL: $apiBaseURL, showLegalNotice: $showLegalNotice)
        }
        .sheet(item: pointBinding) { info in
            PointSheet(info: info, model: model)
        }
        .sheet(item: deptBinding) { info in
            DeptSheet(info: info, model: model)
        }
        .sheet(isPresented: $showLegend) {
            LegendSheet(model: model)
        }
        .alert(LegalNotice.title, isPresented: $showLegalNotice) {
            Button("J'ai compris") { legalNoticeAcknowledged = true }
        } message: {
            Text(LegalNotice.text)
        }
    }

    /// Calque en haut (groupes, espèces, potentiel toute saison), légende à droite.
    private var controls: some View {
        HStack {
            Menu {
                Picker("Espèce ou groupe", selection: layerBinding) {
                    ForEach(model.layers) { layer in
                        Text(layer.title).tag(Optional(layer.key))
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle(isOn: potentialBinding) {
                    Label("Afficher le potentiel toute saison", systemImage: "leaf")
                }
                Text("Le terrain seul, sans la météo ni la saison : pour repérer des secteurs.")
            } label: {
                HStack(spacing: 4) {
                    Text(model.selectedLayer?.title ?? "Couche")
                        .fontWeight(.semibold)
                    Image(systemName: "chevron.down").font(.caption)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.layers.isEmpty)
            .accessibilityLabel("Couche : \(model.selectedLayer?.title ?? "aucune")")
            if model.isLoading || model.isInspecting || model.isLoadingWeather {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button {
                showLegend = true
            } label: {
                Image(systemName: "info")
                    .fontWeight(.semibold)
                    .padding(10)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Légende")
        }
    }

    /// Bandeau du bas : les onze jours (mode score) ou le rappel du potentiel (mode terrain),
    /// puis les messages (vue France, météo, erreurs, envois en attente).
    private var panel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.mode == .score {
                DayStrip(model: model)
                if model.isFranceView {
                    Text(model.deptStatus ?? "Vue par département : zoomez pour voir la parcelle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let status = model.weatherStatus {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("Potentiel terrain, indépendant de la météo et de la saison", systemImage: "leaf")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error = model.loadError ?? model.inspectError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var potentialBinding: Binding<Bool> {
        Binding(get: { model.mode == .terrain }, set: { model.setMode($0 ? .terrain : .score) })
    }

    private var layerBinding: Binding<LayerKey?> {
        Binding(get: { model.selectedLayer?.key }, set: { model.select(layerKey: $0) })
    }

    private var pointBinding: Binding<PointInfo?> {
        Binding(get: { model.pointInfo }, set: { if $0 == nil { model.clearSelection() } })
    }

    private var deptBinding: Binding<DeptInfo?> {
        Binding(get: { model.deptInfo }, set: { if $0 == nil { model.clearDeptInfo() } })
    }

    static func url(from text: String) -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil, url.host() != nil {
            return url
        }
        return URL(string: defaultAPIBaseURL)!
    }
}

/// Légende : seuils et couleurs de la palette servie par l'API. La couleur ne porte jamais seule
/// l'information : chaque pastille a son libellé.
struct LegendView: View {
    let thresholds: [Palette.Threshold]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(thresholds, id: \.label) { threshold in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: threshold.hex))
                        .frame(width: 14, height: 14)
                    Text(threshold.fr)
                        .font(.caption)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Bandeau des onze jours (lot 2) : une pastille par jour, colorée par l'indice du département sous
/// le centre de la carte, l'initiale du jour dessous, aujourd'hui en gras ; les jours passés restent
/// consultables. Remplace le curseur J−3 → J+7 : on choisit une date, pas un décalage.
struct DayStrip: View {
    let model: MapModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(model.dayDots) { dot in
                Button {
                    model.setDay(dot.offset)
                } label: {
                    VStack(spacing: 4) {
                        ScoreDot(value: dot.value, model: model, size: 14, selected: dot.offset == model.dayOffset)
                        Text(dot.date.map { CoinTrend.initial(iso: $0) } ?? "·")
                            .font(.caption2)
                            .fontWeight(dot.offset == 0 ? .bold : .regular)
                            .foregroundStyle(dot.offset == 0 ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(dot))
                .accessibilityAddTraits(dot.offset == model.dayOffset ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Jour : \(model.dayLabel)")
    }

    private func label(_ dot: DayDot) -> String {
        let day = dot.date.map { CoinTrend.shortDay(iso: $0) } ?? (dot.offset == 0 ? "aujourd'hui" : "J\(dot.offset > 0 ? "+" : "")\(dot.offset)")
        let state = dot.value.flatMap { model.classify($0)?.fr } ?? "pas d'indice"
        return "\(day) : \(state)"
    }
}

/// Légende (lot 2) : les cinq couleurs et leurs mots, ce que veut dire un pixel transparent, et
/// le renvoi vers Comprendre. La couleur ne porte jamais seule l'information.
struct LegendSheet: View {
    let model: MapModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.legend, id: \.label) { threshold in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(hex: threshold.hex))
                                .frame(width: 22, height: 16)
                            Text(threshold.fr)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.secondary, lineWidth: 1)
                            .frame(width: 22, height: 16)
                        Text("Transparent : hors forêt ou sans donnée")
                    }
                    .accessibilityElement(children: .combine)
                } header: {
                    Text("Ce que montrent les couleurs")
                } footer: {
                    Text("Le terrain, la météo des dernières semaines et la saison de l'espèce, en un seul score. Le détail est dans l'onglet Comprendre.")
                }
            }
            .navigationTitle("Légende")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }
}

extension Color {
    /// Couleur d'un `hex` de la palette (`#RRGGBB` ou `#RRGGBBAA`).
    init(hex: String) {
        let c = RGBA(hex: hex) ?? .clear
        self.init(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255, opacity: Double(c.a) / 255)
    }
}

/// Avertissement sur le cadre légal de la cueillette, visible depuis la carte (décision du
/// 30 oct. 2026 : finesse de 25 m publique, accompagnée de cet avertissement).
nonisolated enum LegalNotice {
    static let title = "Cadre légal de la cueillette"
    static let text = """
    Champis indique un potentiel, pas une autorisation. En forêt privée, la cueillette suppose \
    l'accord du propriétaire. En forêt publique, elle est tolérée pour une consommation familiale, \
    en quantité limitée, et peut être restreinte ou interdite par arrêté préfectoral ou municipal. \
    Renseignez-vous avant de partir et respectez les lieux.
    """
}

/// Réglages : fond de carte, opacité de l'overlay, adresse de l'API, rappel du cadre légal.
struct SettingsView: View {
    @Bindable var model: MapModel
    @Binding var apiBaseURL: String
    @Binding var showLegalNotice: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Carte") {
                    Picker("Fond", selection: $model.basemap) {
                        ForEach(Basemap.allCases) { basemap in
                            Text(basemap.title).tag(basemap)
                        }
                    }
                    LabeledContent("Opacité") {
                        Slider(value: $model.overlayOpacity, in: 0.2...1)
                            .accessibilityValue("\(Int(model.overlayOpacity * 100)) %")
                    }
                }
                Section("Serveur") {
                    TextField("Adresse de l'API", text: $apiBaseURL)
                        .autocorrectionDisabled()
                    if let catalog = model.catalog {
                        LabeledContent("Scoring", value: catalog.scoringVersion)
                        LabeledContent("Espèces", value: "\(catalog.species.count)")
                    }
                }
                Section {
                    NavigationLink {
                        OfflineView(offline: model.offline, model: model)
                    } label: {
                        LabeledContent("Départements embarqués", value: "\(model.offline.departments.filter(\.complete).count)")
                    }
                    LabeledContent("Tuiles en cache", value: cacheSizeText)
                    Button("Vider le cache des tuiles", role: .destructive) {
                        Task { await model.clearTileCache() }
                    }
                } header: {
                    Text("Hors ligne")
                } footer: {
                    Text("Les départements embarqués se lisent sans réseau, météo du téléchargement comprise ; les tuiles déjà vues aussi.")
                }
                Section {
                    LabeledContent("Observations", value: "\(model.field.observations.count)")
                    LabeledContent("Coins", value: "\(model.field.coins.count)")
                    Button("Supprimer mes observations et mes coins", role: .destructive) {
                        confirmDelete = true
                    }
                    .disabled(model.field.userID == nil)
                    if let status = model.field.status {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Mes données")
                } footer: {
                    Text("Observations et coins sont privés, liés à un identifiant anonyme de l'app. La suppression efface tout sur le serveur et sur l'appareil.")
                }
                Section {
                    Button(LegalNotice.title) {
                        dismiss()
                        showLegalNotice = true
                    }
                }
            }
            .confirmationDialog(
                "Supprimer toutes mes observations et mes coins ?", isPresented: $confirmDelete, titleVisibility: .visible
            ) {
                Button("Tout supprimer", role: .destructive) {
                    let field = model.field
                    Task { await field.deleteAll() }
                }
            } message: {
                Text("Le serveur efface vos lignes, l'appareil aussi. Il n'y a pas de retour.")
            }
            .navigationTitle("Réglages")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .task { await model.refreshTileCacheSize() }
        }
    }

    private var cacheSizeText: String {
        guard let size = model.tileCacheSize else { return "…" }
        return size.formatted(.byteCount(style: .file))
    }
}

#Preview {
    MapScreen(model: MapModel(apiBaseURL: URL(string: MapScreen.defaultAPIBaseURL)!))
}
