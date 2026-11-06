import ChampisScoring
import SwiftUI

/// Onglet Carte (refonte UX, lot 2) : overlay colorisé sur fond Apple, à tout zoom (plus de vue
/// France, décision du 4 nov. 2026), menu de calque (groupes, espèces, potentiel toute saison),
/// légende, fiche au toucher en clair. Les coins ont leur onglet (`CoinsScreen`). Lot 3 : appui
/// long pour le menu de terrain, « Noté : rien trouvé » annulable, proposition d'embarquer le
/// département d'un nouveau coin ; sur iPad et Mac (`layout: .split`), les fiches vont dans
/// l'inspecteur de `SplitContentView`, pas en feuille. Étape A (6 nov. 2026) : la carte montre
/// toujours aujourd'hui, le bandeau des jours est retiré (les onze jours sont dans la fiche d'un
/// point, en lecture seule), et les réglages s'ouvrent aussi d'ici.
struct MapScreen: View {
    static let defaultAPIBaseURL = "https://champis.app"

    nonisolated enum Layout: Sendable {
        /// iPhone : les fiches sont des feuilles.
        case compact
        /// iPad et Mac : les fiches sont dans l'inspecteur, l'écran n'en présente pas.
        case split
    }

    /// Modèle partagé par les trois onglets, créé et démarré par `ContentView`.
    let model: MapModel
    var layout: Layout = .compact
    @State private var showLegend = false
    @State private var showSettings = false
    @State private var showLegalNotice = false
    @AppStorage("apiBaseURL") private var apiBaseURL = MapScreen.defaultAPIBaseURL
    @State private var observationRequest: ObservationFormRequest?
    @State private var quickFound: MapSelection?

    var body: some View {
        NavigationStack {
            ZStack {
                // la carte occupe tout l'écran, sous la barre d'état, la barre d'outils et la barre
                // d'onglets ; les commandes restent dans la zone sûre
                MapContainer(model: model)
                    .accessibilityLabel("Carte des champignons")
                    .ignoresSafeArea()
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        Button {
                            model.locateMe()
                        } label: {
                            Image(systemName: model.locationDenied ? "location.slash" : "location")
                                .font(.body.weight(.medium))
                                .padding(6)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Centrer sur ma position")
                        .accessibilityHint(model.locationDenied ? "Position refusée dans les réglages du système" : "")
                    }
                    if !model.field.undoable.isEmpty {
                        undoToast
                    }
                    panel
                }
                .padding(12)
                .animation(.default, value: model.field.undoable.isEmpty)
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            #endif
            .toolbar {
                // le menu de calque à gauche, la légende et le retour terrain à droite : tout en
                // Liquid Glass dans la barre, plus rien de flottant en haut de la carte
                ToolbarItem(placement: Self.leadingPlacement) {
                    layerMenu
                }
                if model.isLoading || model.isInspecting || model.isLoadingWeather {
                    ToolbarItem(placement: Self.leadingPlacement) {
                        ProgressView().controlSize(.small)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showLegend = true
                    } label: {
                        Label("Légende", systemImage: "info")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Réglages", systemImage: "slider.horizontal.3")
                    }
                }
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
            }
        }
        .sheet(item: $observationRequest) { request in
            ObservationForm(
                field: model.field, species: model.speciesOptions, initialSpecies: request.species,
                at: request.point, found: request.found
            )
        }
        .sheet(item: pointBinding) { info in
            PointSheet(info: info, model: model)
        }
        .sheet(isPresented: $showLegend) {
            LegendSheet(model: model)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model, apiBaseURL: $apiBaseURL, showLegalNotice: $showLegalNotice)
        }
        .alert(LegalNotice.title, isPresented: $showLegalNotice) {
            Button("OK") {}
        } message: {
            Text(LegalNotice.text)
        }
        .sheet(item: $quickFound) { point in
            QuickFoundSheet(model: model, point: point, initialSpecies: nil)
        }
        .confirmationDialog(
            "À cet endroit", isPresented: longPressBinding, titleVisibility: .visible, presenting: model.longPressPoint
        ) { point in
            Button("Trouvé ici") {
                quickFound = point
            }
            Button("Rien trouvé ici") {
                let field = model.field
                let species = model.layerSpecies
                Task { await field.recordNotFound(species: species, latitude: point.latitude, longitude: point.longitude) }
            }
            .disabled(model.layerSpecies.isEmpty)
            Button("Ajouter à mes coins") {
                model.requestCoin(latitude: point.latitude, longitude: point.longitude)
            }
        } message: { _ in
            Text(model.selectedLayer.map { "Pour \($0.title)." } ?? "")
        }
        .alert(
            offlineTitle, isPresented: offlineBinding, presenting: model.offlineSuggestion
        ) { _ in
            Button("Embarquer") { model.acceptOfflineSuggestion() }
            Button("Non merci", role: .cancel) { model.declineOfflineSuggestion() }
        } message: { choice in
            Text(
                "\(Self.sizeText(choice)) : la carte et la météo de toutes les espèces se liront sans réseau. " +
                "Modifiable plus tard dans les réglages."
            )
        }
        .onChange(of: model.field.undoable.isEmpty) { _, empty in
            if !empty {
                AccessibilityNotification.Announcement("Noté : rien trouvé. Annuler possible pendant cinq secondes.").post()
            }
        }
    }

    /// À gauche de la barre d'outils sur iOS, dans la zone de navigation sur Mac.
    private static var leadingPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    /// Menu de calque (groupes, espèces, potentiel toute saison, fond de carte), dans la barre.
    private var layerMenu: some View {
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
            Divider()
            Picker("Fond de carte", selection: basemapBinding) {
                ForEach(Basemap.allCases) { basemap in
                    Text(basemap.title).tag(basemap)
                }
            }
            .pickerStyle(.menu)
        } label: {
            HStack(spacing: 4) {
                Text(model.selectedLayer?.title ?? "Couche")
                    .fontWeight(.semibold)
                Image(systemName: "chevron.down").font(.caption)
            }
        }
        .disabled(model.layers.isEmpty)
        .accessibilityLabel("Couche : \(model.selectedLayer?.title ?? "aucune")")
    }

    /// Bandeau du bas : les onze jours (mode score) ou le rappel du potentiel (mode terrain),
    /// puis les messages (météo, erreurs, envois en attente).
    private var panel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.mode == .score {
                // la carte montre toujours aujourd'hui : on le dit, à la place du bandeau des jours
                Text(model.dayLabel)
                    .font(.subheadline.weight(.semibold))
                if let status = model.weatherStatus {
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

    /// « Noté : rien trouvé » avec Annuler, le temps du délai avant l'envoi.
    private var undoToast: some View {
        HStack {
            Label("Noté : rien trouvé", systemImage: "checkmark")
                .font(.subheadline)
            Spacer()
            Button("Annuler") {
                let field = model.field
                Task { await field.undoNotFound() }
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var offlineTitle: String {
        guard let choice = model.offlineSuggestion else { return "" }
        return "Embarquer \(choice.name ?? "le département \(choice.code)") pour la forêt ?"
    }

    static func sizeText(_ choice: DownloadableDepartment) -> String {
        choice.bytes(for: choice.species).formatted(.byteCount(style: .file))
    }

    private var longPressBinding: Binding<Bool> {
        Binding(get: { model.longPressPoint != nil }, set: { if !$0 { model.clearLongPress() } })
    }

    private var offlineBinding: Binding<Bool> {
        Binding(get: { model.offlineSuggestion != nil }, set: { if !$0, model.offlineSuggestion != nil { model.declineOfflineSuggestion() } })
    }

    private var basemapBinding: Binding<Basemap> {
        Binding(get: { model.basemap }, set: { model.basemap = $0 })
    }

    private var potentialBinding: Binding<Bool> {
        Binding(get: { model.mode == .terrain }, set: { model.setMode($0 ? .terrain : .score) })
    }

    private var layerBinding: Binding<LayerKey?> {
        Binding(get: { model.selectedLayer?.key }, set: { model.select(layerKey: $0) })
    }

    /// En disposition partagée, l'inspecteur montre la fiche : la feuille ne se présente jamais.
    private var pointBinding: Binding<PointInfo?> {
        Binding(get: { layout == .compact ? model.pointInfo : nil }, set: { if $0 == nil { model.clearSelection() } })
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

/// Légende (lot 2) : les cinq couleurs et leurs mots, ce que veut dire un pixel transparent, et
/// le renvoi vers Comprendre. La couleur ne porte jamais seule l'information.
struct LegendSheet: View {
    let model: MapModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.paintedLegend, id: \.label) { threshold in
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
                        Text(model.transparentLegendText)
                    }
                    .accessibilityElement(children: .combine)
                } header: {
                    Text("Ce que montrent les couleurs")
                } footer: {
                    Text("Le terrain, la météo des dernières semaines et la saison de l'espèce, en un seul score. Le détail est dans l'onglet Guide.")
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

#Preview {
    MapScreen(model: MapModel(apiBaseURL: URL(string: MapScreen.defaultAPIBaseURL)!))
}
