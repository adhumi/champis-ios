import ChampisPMTiles
import ChampisScoring
import Foundation
import MapKit
import Observation

/// Fond de carte Apple sous l'overlay.
nonisolated enum Basemap: String, CaseIterable, Identifiable, Sendable {
    case standard
    case satellite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Plan"
        case .satellite: "Satellite"
        }
    }
}

/// Point touché sur la carte.
nonisolated struct MapSelection: Hashable, Sendable {
    let latitude: Double
    let longitude: Double
}

/// Département touché en vue France ; `code` nil = hors département.
nonisolated struct DeptInfo: Identifiable, Sendable {
    let id = UUID()
    let code: String?
    let name: String?
    let date: String?
    let row: DeptDay?
    let layerTitle: String?
}

/// Modèle de l'écran carte (MVVM, `@Observable`, MainActor). Les vues ne calculent rien : espèce
/// ou groupe courant, jour, mode T/S, météo chargée, indice par département, fiche du point touché,
/// état de chargement. Les tuiles se lisent et se colorisent hors du MainActor (`TileStore`,
/// `TileRenderer`) ; le modèle leur pousse ses réglages.
@Observable
final class MapModel {
    static let dayRange = -3...7
    /// Marge autour de l'emprise visible pour la météo (une cellule, comme la carte web).
    static let weatherPaddingDegrees = 0.1
    /// En dessous de ce zoom, en mode score, la carte passe aux départements (comme le site).
    static let deptZoom = 9.0
    /// Centre de la France, vue d'ensemble, tant qu'on n'a pas de position.
    static let initialRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 46.8, longitude: 2.4),
        span: MKCoordinateSpan(latitudeDelta: 9, longitudeDelta: 9)
    )

    // Réglages
    private(set) var layers: [Layer] = []
    private(set) var selectedLayer: Layer?
    private(set) var dayOffset = 0
    private(set) var mode: MapMode = .score
    var basemap: Basemap = .standard
    var overlayOpacity = 0.75

    // État
    private(set) var catalog: SpeciesCatalog?
    private(set) var manifest: TilesManifest?
    private(set) var weather = WeatherField()
    private(set) var weatherStatus: String?
    private(set) var isLoading = false
    private(set) var isLoadingWeather = false
    private(set) var loadError: String?
    /// Zoom Web Mercator de la vue ; `nil` tant que la carte n'a pas donné sa première région.
    private(set) var zoom: Double?
    /// Incrémenté à chaque réglage poussé au rendu : la vue carte redessine tuiles et départements.
    private(set) var renderGeneration = 0

    // Vue France
    private(set) var deptIndex: DeptIndex?
    private(set) var deptStatus: String?
    private(set) var deptFeatures: [MKGeoJSONFeature] = []
    private(set) var deptInfo: DeptInfo?

    // Fiche au toucher
    private(set) var selection: MapSelection?
    private(set) var pointInfo: PointInfo?
    private(set) var isInspecting = false
    private(set) var inspectError: String?
    private(set) var pointFactors: [String: Double]?
    private(set) var factorsStatus: String?

    let overlay: ScoreTileOverlay
    @ObservationIgnored private let renderer: TileRenderer
    @ObservationIgnored private let store: TileStore
    @ObservationIgnored private(set) var api: ChampisAPI
    @ObservationIgnored private var visibleBBox: BBox?
    @ObservationIgnored private var weatherTask: Task<Void, Never>?
    @ObservationIgnored private var deptTask: Task<Void, Never>?
    @ObservationIgnored private var inspectTask: Task<Void, Never>?
    @ObservationIgnored private var isLoadingBoundaries = false

    init(apiBaseURL: URL) {
        api = ChampisAPI(baseURL: apiBaseURL)
        store = TileStore()
        renderer = TileRenderer(store: store)
        overlay = ScoreTileOverlay(renderer: renderer)
    }

    var palette: Palette? { catalog?.palette }
    var legend: [Palette.Threshold] { catalog?.palette.thresholds ?? [] }
    /// Mode score sous le zoom seuil : départements colorés par l'indice au lieu des tuiles.
    var isFranceView: Bool {
        guard let zoom else { return false }
        return mode == .score && zoom < Self.deptZoom
    }

    /// `today` de l'API, par la météo ou l'indice par département, selon ce qui est arrivé.
    var today: String? { weather.today ?? deptIndex?.today }

    /// Jour affiché (ISO) ; `nil` tant que l'API n'a rien dit.
    var dayDate: String? {
        guard let today, let date = try? CivilDate(iso: today) else { return nil }
        return date.adding(days: dayOffset).description
    }

    var dayLabel: String {
        let k = dayOffset
        let relative = k == 0 ? "Aujourd'hui" : (k > 0 ? "J+\(k)" : "J−\(-k)")
        guard let date = dayDate else { return relative }
        return "\(relative) · \(Self.format(iso: date))"
    }

    func speciesName(_ id: String) -> String {
        catalog?.species[id]?.names?.fr ?? id
    }

    func classify(_ value: Double) -> Palette.Threshold? {
        palette?.classify(value)
    }

    /// `2026-10-30` → `jeu. 30 oct.` (locale de l'appareil).
    static func format(iso: String) -> String {
        guard let d = try? CivilDate(iso: iso) else { return iso }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
        guard let date = calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: 12)) else {
            return iso
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// Horodatage ISO 8601 de l'API → date et heure locales courtes.
    static func format(timestamp: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: timestamp) else { return timestamp }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Chargement

    /// Démarre (ou redémarre, si l'adresse de l'API a changé) : espèces, palette, manifeste des tuiles.
    func start(apiBaseURL: URL) async {
        if apiBaseURL != api.baseURL {
            api = ChampisAPI(baseURL: apiBaseURL)
            weather = WeatherField()
            weatherStatus = nil
            deptIndex = nil
            deptFeatures = []
        }
        await load()
    }

    func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let catalog = try await api.species()
            let manifest = try await api.tiles()
            self.catalog = catalog
            self.manifest = manifest
            layers = LayerCatalog.layers(from: catalog)
            await store.configure(manifest: manifest, api: api, scoringVersion: ChampisScoring.supportedScoringVersion)
            if !manifest.configured {
                loadError = "Le serveur n'a pas de tuiles configurées (GET /tiles)."
            }
            if selectedLayer == nil || !layers.contains(where: { $0.key == selectedLayer?.key }) {
                selectedLayer = layers.first
            }
            pushSettings()
            refreshData()
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Réglages

    func select(layerKey: LayerKey?) {
        selectedLayer = layers.first { $0.key == layerKey }
        pushSettings()
        refreshData()
    }

    func setDay(_ offset: Int) {
        dayOffset = min(max(offset, Self.dayRange.lowerBound), Self.dayRange.upperBound)
        pushSettings()
    }

    func setMode(_ mode: MapMode) {
        self.mode = mode
        pushSettings()
        refreshData()
    }

    func visibleRegionChanged(_ bbox: BBox, zoom: Double) {
        visibleBBox = bbox
        let wasFranceView = isFranceView
        self.zoom = zoom
        if isFranceView != wasFranceView {
            pushSettings()
        }
        refreshData(debounce: true)
    }

    /// Selon la vue : l'indice par département (vue France) ou la météo de l'emprise.
    private func refreshData(debounce: Bool = false) {
        if isFranceView {
            weatherTask?.cancel()
            refreshDeptIndex()
        } else {
            deptTask?.cancel()
            refreshWeather(debounce: debounce)
        }
    }

    // MARK: - Météo

    /// `GET /weather/bbox` sur l'emprise visible (avec marge) pour les espèces de la couche ; les
    /// 11 jours arrivent d'un coup, le curseur de jour ne recharge rien.
    private func refreshWeather(debounce: Bool = false) {
        weatherTask?.cancel()
        guard mode == .score, let layer = selectedLayer, let bbox = visibleBBox, catalog != nil else {
            weatherStatus = nil
            return
        }
        let api = api
        weatherTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(400))
            }
            guard !Task.isCancelled, let self else { return }
            isLoadingWeather = true
            defer { isLoadingWeather = false }
            do {
                let response = try await api.weather(bbox: bbox.padded(by: Self.weatherPaddingDegrees), species: layer.members)
                guard !Task.isCancelled else { return }
                weather.merge(response)
                weatherStatus = Self.status(for: response)
                pushSettings()
            } catch let failure as ChampisAPI.Failure {
                guard !Task.isCancelled else { return }
                if case .http(let status, let detail) = failure, status == 422 {
                    weatherStatus = detail.isEmpty ? "Zoomez pour afficher la météo" : detail
                } else {
                    weatherStatus = "Météo indisponible : \(failure.localizedDescription)"
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                weatherStatus = "Météo indisponible : \(error.localizedDescription)"
            }
        }
    }

    static func status(for response: WeatherBBoxResponse) -> String {
        var parts = ["\(response.cells.count) cellule(s) météo"]
        if response.cells.contains(where: { $0.stale }) {
            parts.append("cache périmé")
        }
        if !response.unavailable.isEmpty {
            var missing = "\(response.unavailable.count) sans météo"
            if let retry = response.retryAfter {
                missing += ", réessai dans \(retry) s"
            }
            parts.append(missing)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Vue France

    /// `GET /departements` pour la couche : 11 jours d'un coup, le curseur ne recharge rien. Les
    /// limites (GeoJSON servi avec le site) se chargent une fois.
    private func refreshDeptIndex() {
        guard isFranceView, let layer = selectedLayer, catalog != nil else { return }
        if deptFeatures.isEmpty {
            loadBoundaries()
        }
        if let deptIndex, deptIndex.layerKey == layer.key {
            return
        }
        deptTask?.cancel()
        let api = api
        deptTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await api.departements(species: layer.members)
                guard !Task.isCancelled else { return }
                deptIndex = DeptIndex(response: response, layer: layer)
                deptStatus = "Indice par département calculé le \(Self.format(timestamp: response.computedAt))"
                pushSettings()
            } catch let failure as ChampisAPI.Failure {
                guard !Task.isCancelled else { return }
                deptStatus = "Vue France indisponible : \(failure.localizedDescription)"
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                deptStatus = "Vue France indisponible : \(error.localizedDescription)"
            }
        }
    }

    private func loadBoundaries() {
        guard !isLoadingBoundaries else { return }
        isLoadingBoundaries = true
        let api = api
        Task { [weak self] in
            guard let self else { return }
            defer { isLoadingBoundaries = false }
            do {
                let data = try await api.departementsGeoJSON()
                let objects = try MKGeoJSONDecoder().decode(data)
                deptFeatures = objects.compactMap { $0 as? MKGeoJSONFeature }
            } catch {
                deptStatus = "Limites des départements indisponibles : \(error.localizedDescription)"
            }
        }
    }

    /// Couleur d'un département pour la couche et le jour courants ; `nil` = transparent (pas
    /// d'indice : jamais une valeur inventée).
    func deptColor(code: String) -> RGBA? {
        guard let deptIndex, let date = dayDate, let palette,
              let value = deptIndex.value(code: code, date: date)
        else { return nil }
        return RGBA(hex: palette.classify(value).hex)
    }

    func selectDepartement(code: String?, name: String?) {
        let date = dayDate
        var row: DeptDay?
        if let code, let date {
            row = deptIndex?.row(code: code, date: date)
        }
        deptInfo = DeptInfo(code: code, name: name, date: date, row: row, layerTitle: selectedLayer?.title)
    }

    func clearDeptInfo() {
        deptInfo = nil
    }

    // MARK: - Fiche au toucher

    func select(latitude: Double, longitude: Double) {
        selection = MapSelection(latitude: latitude, longitude: longitude)
        inspectTask?.cancel()
        pointFactors = nil
        factorsStatus = nil
        inspectError = nil
        let settings = currentSettings()
        let store = store
        isInspecting = true
        inspectTask = Task { [weak self] in
            guard let self else { return }
            defer { isInspecting = false }
            do {
                let info = try await PointInspector.inspect(
                    latitude: latitude, longitude: longitude, settings: settings, store: store
                )
                guard !Task.isCancelled else { return }
                pointInfo = info
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                inspectError = "Lecture du point impossible : \(error.localizedDescription)"
            }
        }
    }

    /// Facteurs météo du point (`GET /weather?cell=&species=`), pour la fiche.
    func loadFactors(for info: PointInfo) async {
        guard case .scored(let scored) = info.outcome, let cell = scored.cell, let date = info.date,
              let altKey = scored.altKey
        else { return }
        factorsStatus = nil
        do {
            let detail = try await api.weatherDetail(cell: cell.id, species: [scored.species])
            let row = detail.species[scored.species]?.first { $0.date == date }?.byAlt[altKey]
            pointFactors = row?.factors
            if pointFactors == nil {
                factorsStatus = "Facteurs indisponibles pour ce jour."
            }
        } catch {
            factorsStatus = "Facteurs indisponibles : \(error.localizedDescription)"
        }
    }

    func clearSelection() {
        inspectTask?.cancel()
        selection = nil
        pointInfo = nil
        pointFactors = nil
        factorsStatus = nil
    }

    // MARK: - Rendu

    private func currentSettings() -> RenderSettings {
        RenderSettings(
            layer: selectedLayer,
            mode: mode,
            date: dayDate,
            weather: weather,
            colorizer: catalog.map { TileColorizer(palette: $0.palette) }
        )
    }

    private func pushSettings() {
        renderer.update(currentSettings())
        renderGeneration += 1
    }
}
