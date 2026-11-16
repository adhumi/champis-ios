import ChampisScoring
import SwiftUI

/// Onglet Carte (refonte UX, lot 2) : overlay colorisé sur fond Apple, à tout zoom (plus de vue
/// France, décision du 4 nov. 2026), sélecteur d'espèce, légende, fiche au toucher en clair. Les
/// coins ont leur onglet (`CoinsScreen`). Lot 3 : appui long pour le menu de terrain, « Noté : rien
/// trouvé » annulable, proposition d'embarquer le département d'un nouveau coin ; sur iPad et Mac
/// (`layout: .split`), les fiches vont dans l'inspecteur de `SplitContentView`, pas en feuille.
/// Étape A (6 nov. 2026) : la carte montre toujours aujourd'hui, les onze jours sont dans la fiche
/// d'un point, en lecture seule.
///
/// Écran allégé le 9 nov. 2026 : dans la barre, le sélecteur d'espèce (vignette et nom) et la
/// légende seulement ; plus de potentiel toute saison, plus de réglages (onglets Mes coins et
/// Guide), plus de menu Retour terrain ni de bouton « Noter » : on note depuis le point touché
/// (fiche) ou pressé (menu). Le fond de carte a son bouton sous « Centrer sur ma position ». Sous la
/// carte, rien, sauf une erreur ou une information qui change sa lecture (`MapModel.hasNotice`).
struct MapScreen: View {
    /// L'API est sur son propre domaine depuis le découpage des dépôts (spec › Produit › Étape C,
    /// lot C7, 6 nov. 2026) ; `champis.app` est le site, qui ne relaie plus l'API depuis le
    /// 13 nov. 2026 (404 hors de ses fichiers).
    static let defaultAPIBaseURL = "https://api.champis.app"
    /// Ancienne adresse par défaut, peut-être gardée par `@AppStorage` : lue comme la nouvelle.
    static let legacyAPIBaseURLs: Set<String> = ["https://champis.app", "https://champis.app/"]
    /// Côté du glyphe des boutons ronds de la carte : un cadre fixe, pour que les cercles aient la
    /// même taille quel que soit le symbole.
    private static let controlGlyphSide: CGFloat = 22

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
    @State private var quickFound: MapSelection?
    /// Le réglage de l'adresse de l'API, pour y revenir depuis le bandeau de lecture seule.
    @AppStorage("apiBaseURL") private var apiBaseURL = MapScreen.defaultAPIBaseURL

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
                        VStack(spacing: 8) {
                            locateButton
                            basemapMenu
                        }
                    }
                    if !model.field.undoable.isEmpty {
                        undoToast
                    }
                    if model.hasNotice {
                        notices
                    }
                    if let host = model.customAPIHost {
                        ReadOnlyBanner(host: host) { apiBaseURL = MapScreen.defaultAPIBaseURL }
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(12)
                .animation(.default, value: model.field.undoable.isEmpty)
                .animation(.default, value: model.hasNotice)
                .animation(.default, value: model.customAPIHost)
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            #endif
            .toolbar {
                // le sélecteur d'espèce à gauche, la légende à droite : tout en Liquid Glass dans
                // la barre, plus rien de flottant en haut de la carte
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
            }
        }
        .sheet(item: pointBinding) { info in
            PointSheet(info: info, model: model)
        }
        .sheet(isPresented: $showLegend) {
            LegendSheet(model: model)
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

    /// Sélecteur d'espèce (9 nov. 2026, comme celui du site) : dans la barre, la vignette
    /// naturaliste et le nom de la couche ; dans le menu, les groupes (nom latin des genres en
    /// sous-titre), un séparateur, puis les espèces (nom latin en sous-titre).
    private var layerMenu: some View {
        Menu {
            Section {
                ForEach(model.groupLayers) { layer in
                    layerToggle(layer)
                }
            }
            Section {
                ForEach(model.speciesLayers) { layer in
                    layerToggle(layer)
                }
            }
        } label: {
            HStack(spacing: 8) {
                SpeciesThumbnail(species: model.selectedLayer?.illustration)
                Text(model.selectedLayer?.title ?? "Espèce")
                    .fontWeight(.semibold)
                Image(systemName: "chevron.down").font(.caption)
            }
        }
        .disabled(model.layers.isEmpty)
        .accessibilityLabel("Espèce : \(model.selectedLayer?.title ?? "aucune")")
    }

    /// Une ligne du menu : coche sur la couche affichée, nom français, nom latin en sous-titre.
    private func layerToggle(_ layer: Layer) -> some View {
        Toggle(isOn: layerBinding(layer)) {
            Text(layer.title)
            if !layer.latin.isEmpty {
                Text(layer.latin)
            }
        }
    }

    /// Centrer sur ma position : bouton rond en verre, en bas à droite.
    private var locateButton: some View {
        Button {
            model.locateMe()
        } label: {
            controlGlyph(model.locationDenied ? "location.slash" : "location")
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Centrer sur ma position")
        .accessibilityHint(model.locationDenied ? "Position refusée dans les réglages du système" : "")
    }

    /// Fond de carte (plan ou satellite) : même bouton rond, sous « Centrer sur ma position ».
    private var basemapMenu: some View {
        Menu {
            Picker("Fond de carte", selection: basemapBinding) {
                ForEach(Basemap.allCases) { basemap in
                    Label(basemap.title, systemImage: basemap.systemImage).tag(basemap)
                }
            }
            .pickerStyle(.inline)
        } label: {
            controlGlyph("square.2.layers.3d")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Fond de carte")
        .accessibilityValue(model.basemap.title)
    }

    private func controlGlyph(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.body.weight(.medium))
            .frame(width: Self.controlGlyphSide, height: Self.controlGlyphSide)
            .padding(6)
    }

    /// Sous la carte, seulement quand il y a quelque chose à dire : une erreur avec sa reprise, ou
    /// une information qui change la lecture de la carte (hors ligne, zones sans météo).
    private var notices: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let problem = model.weatherProblem {
                ProblemView(problem: problem) { model.retryWeather() }
            } else if let notice = model.weatherNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.footnote)
            }
            if let problem = model.problem {
                ProblemView(problem: problem) { model.retryProblem() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .transition(.move(edge: .bottom).combined(with: .opacity))
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

    /// Cocher une couche l'affiche ; décocher celle affichée ne fait rien (il en faut une).
    private func layerBinding(_ layer: Layer) -> Binding<Bool> {
        Binding(get: { model.selectedLayer?.key == layer.key }, set: { if $0 { model.select(layerKey: layer.key) } })
    }

    /// En disposition partagée, l'inspecteur montre la fiche : la feuille ne se présente jamais.
    private var pointBinding: Binding<PointInfo?> {
        Binding(get: { layout == .compact ? model.pointInfo : nil }, set: { if $0 == nil { model.clearSelection() } })
    }

    /// Adresse de l'API d'après le réglage : https exigé (`ChampisAPI.isAcceptable`), sinon
    /// l'adresse officielle. Une autre adresse que l'officielle met l'app en lecture seule.
    static func url(from text: String) -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !legacyAPIBaseURLs.contains(trimmed), let url = URL(string: trimmed), ChampisAPI.isAcceptable(url) {
            return url
        }
        return URL(string: defaultAPIBaseURL)!
    }
}

/// Bandeau permanent quand l'adresse de l'API n'est pas l'officielle (décision du 13 nov. 2026) :
/// l'app lit seulement, sans identifiant ; observations et coins restent sur l'appareil. Sur la
/// carte et dans les réglages, avec le bouton qui revient à l'adresse officielle.
struct ReadOnlyBanner: View {
    let host: String
    let reset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Lecture seule : l'app lit \(host), pas l'API officielle. Observations et coins restent sur l'appareil, rien n'est envoyé.")
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.orange)
            }
            .font(.footnote)
            Button("Revenir à l'adresse officielle", action: reset)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// Barre continue de la légende (échelle linéaire, 6 nov. 2026) : du transparent au violet de
/// `scale`, sur un fond neutre pour que le transparent se voie, les cinq mots en dessous dans
/// l'ordre des scores (très faible → excellent). La couleur ne porte jamais seule l'information.
struct LegendBar: View {
    let scale: Palette.Scale
    let thresholds: [Palette.Threshold]

    private var words: [Palette.Threshold] { thresholds.sorted { $0.min < $1.min } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .overlay {
                    LinearGradient(
                        colors: [
                            Color(hex: scale.hex).opacity(scale.alphaMin),
                            Color(hex: scale.hex).opacity(scale.alphaMax),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .frame(height: 14)
            HStack(spacing: 0) {
                ForEach(Array(words.enumerated()), id: \.element.label) { index, threshold in
                    if index > 0 { Spacer(minLength: 4) }
                    Text(threshold.fr)
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Du transparent au violet foncé : " + words.map(\.fr).joined(separator: ", "))
    }
}

/// Légende compacte : la barre continue, ou, sans échelle (API ancienne), les pastilles de classe
/// avec leur mot.
struct LegendView: View {
    let scale: Palette.Scale?
    let thresholds: [Palette.Threshold]

    var body: some View {
        if let scale {
            LegendBar(scale: scale, thresholds: thresholds)
        } else {
            HStack(spacing: 10) {
                ForEach(thresholds, id: \.label) { threshold in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(hex: threshold.hex))
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.5), lineWidth: 0.5))
                            .frame(width: 14, height: 14)
                        Text(threshold.fr)
                            .font(.caption)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// Légende (lot 2, échelle linéaire le 6 nov. 2026) : la barre continue du transparent au violet
/// avec les cinq mots, ce que veut dire un pixel transparent, et le renvoi vers Comprendre. Sans
/// échelle (API ancienne), les cinq pastilles de classe. La couleur ne porte jamais seule l'information.
/// Depuis le 9 nov. 2026, elle porte aussi l'avertissement sur le cadre légal de la cueillette.
struct LegendSheet: View {
    let model: MapModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let scale = model.palette?.scale {
                        LegendBar(scale: scale, thresholds: model.legend)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(model.legend, id: \.label) { threshold in
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(hex: threshold.hex))
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.5), lineWidth: 0.5))
                                    .frame(width: 22, height: 16)
                                Text(threshold.fr)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.secondary, lineWidth: 1)
                            .frame(width: 22, height: 16)
                        Text("Transparent : hors forêt ou sans donnée")
                    }
                    .accessibilityElement(children: .combine)
                } header: {
                    Text("Ce que montre la couleur")
                } footer: {
                    Text("Plus le violet est foncé, plus les conditions sont réunies : le terrain, la météo des dernières semaines et la saison de l'espèce, en un seul score. Le détail est dans l'onglet Guide.")
                }
                // l'avertissement accompagne la carte (30 oct. 2026) : les réglages n'y sont plus
                // depuis le 9 nov. 2026, il est ici
                Section(LegalNotice.title) {
                    Text(LegalNotice.text)
                        .font(.footnote)
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
        .presentationDetents([.medium, .large])
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
