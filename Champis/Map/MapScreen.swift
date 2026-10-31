import ChampisScoring
import SwiftUI

/// Écran carte : overlay colorisé sur fond Apple (ou départements en vue France), sélecteur d'espèce
/// ou de groupe, mode terrain ou score du jour, curseur de jour J−3 → J+7, légende, fiche au
/// toucher, avertissement sur le cadre légal.
struct MapScreen: View {
    static let defaultAPIBaseURL = "https://champis.adhumi.fr"

    @AppStorage("apiBaseURL") private var apiBaseURL = MapScreen.defaultAPIBaseURL
    @AppStorage("legalNoticeAcknowledged") private var legalNoticeAcknowledged = false
    @State private var model = MapModel(
        apiBaseURL: URL(string: MapScreen.defaultAPIBaseURL)!, diskCache: try? DiskTileCache.default()
    )
    @State private var showSettings = false
    @State private var showLegalNotice = false

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
                    Button {
                        showSettings = true
                    } label: {
                        Label("Réglages", systemImage: "slider.horizontal.3")
                    }
                }
            }
        }
        .task {
            await model.start(apiBaseURL: Self.url(from: apiBaseURL))
            if !legalNoticeAcknowledged {
                showLegalNotice = true
            }
        }
        .onChange(of: apiBaseURL) { _, newValue in
            Task { await model.start(apiBaseURL: Self.url(from: newValue)) }
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
        .alert(LegalNotice.title, isPresented: $showLegalNotice) {
            Button("J'ai compris") { legalNoticeAcknowledged = true }
        } message: {
            Text(LegalNotice.text)
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Espèce ou groupe", selection: layerBinding) {
                    ForEach(model.layers) { layer in
                        Text(layer.title).tag(Optional(layer.key))
                    }
                }
                .pickerStyle(.menu)
                .disabled(model.layers.isEmpty)
                Spacer()
                if model.isLoading || model.isInspecting {
                    ProgressView().controlSize(.small)
                }
            }
            Picker("Mode", selection: modeBinding) {
                Text("Terrain").tag(MapMode.terrain)
                Text("Score du jour").tag(MapMode.score)
            }
            .pickerStyle(.segmented)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.mode == .score {
                HStack {
                    Text(model.dayLabel)
                        .font(.headline)
                        .monospacedDigit()
                    Spacer()
                    if model.isLoadingWeather {
                        ProgressView().controlSize(.small)
                    }
                }
                Slider(
                    value: dayBinding,
                    in: Double(MapModel.dayRange.lowerBound)...Double(MapModel.dayRange.upperBound),
                    step: 1
                ) {
                    Text("Jour")
                } minimumValueLabel: {
                    Text("J−3").font(.caption)
                } maximumValueLabel: {
                    Text("J+7").font(.caption)
                }
                .accessibilityValue(model.dayLabel)
                if model.isFranceView {
                    Text(model.deptStatus ?? "Vue France : indice par département, zoomez pour les parcelles")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let status = model.weatherStatus {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            LegendView(thresholds: model.legend)
            if let error = model.loadError ?? model.inspectError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var layerBinding: Binding<LayerKey?> {
        Binding(get: { model.selectedLayer?.key }, set: { model.select(layerKey: $0) })
    }

    private var modeBinding: Binding<MapMode> {
        Binding(get: { model.mode }, set: { model.setMode($0) })
    }

    private var dayBinding: Binding<Double> {
        Binding(get: { Double(model.dayOffset) }, set: { model.setDay(Int($0.rounded())) })
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
                    LabeledContent("Tuiles en cache", value: cacheSizeText)
                    Button("Vider le cache des tuiles", role: .destructive) {
                        Task { await model.clearTileCache() }
                    }
                } header: {
                    Text("Hors ligne")
                } footer: {
                    Text("Les tuiles déjà vues restent lisibles sans réseau. Le téléchargement par département viendra ensuite.")
                }
                Section {
                    Button(LegalNotice.title) {
                        dismiss()
                        showLegalNotice = true
                    }
                }
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
    MapScreen()
}
