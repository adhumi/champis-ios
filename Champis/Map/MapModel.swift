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

/// Point touché sur la carte (fiche à venir).
nonisolated struct MapSelection: Hashable, Sendable {
    let latitude: Double
    let longitude: Double
}

/// Modèle de l'écran carte (MVVM, `@Observable`, MainActor). Les vues ne calculent rien : espèce
/// ou groupe courant, jour, mode T/S, météo chargée, état de chargement. Les tuiles se lisent et se
/// colorisent hors du MainActor (`TileStore`, `TileRenderer`) ; le modèle leur pousse ses réglages.
@Observable
final class MapModel {
    static let dayRange = -3...7
    /// Marge autour de l'emprise visible pour la météo (une cellule, comme la carte web).
    static let weatherPaddingDegrees = 0.1
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
    private(set) var selection: MapSelection?
    /// Incrémenté à chaque réglage poussé au rendu : la vue carte redessine ses tuiles.
    private(set) var renderGeneration = 0

    let overlay: ScoreTileOverlay
    @ObservationIgnored private let renderer: TileRenderer
    @ObservationIgnored private let store: TileStore
    @ObservationIgnored private(set) var api: ChampisAPI
    @ObservationIgnored private var visibleBBox: BBox?
    @ObservationIgnored private var weatherTask: Task<Void, Never>?

    init(apiBaseURL: URL) {
        api = ChampisAPI(baseURL: apiBaseURL)
        store = TileStore()
        renderer = TileRenderer(store: store)
        overlay = ScoreTileOverlay(renderer: renderer)
    }

    var palette: Palette? { catalog?.palette }
    var legend: [Palette.Threshold] { catalog?.palette.thresholds ?? [] }

    /// Jour affiché (ISO), à partir du `today` de l'API ; `nil` tant qu'aucune météo n'est connue.
    var dayDate: String? {
        guard let today = weather.today, let date = try? CivilDate(iso: today) else { return nil }
        return date.adding(days: dayOffset).description
    }

    var dayLabel: String {
        let k = dayOffset
        let relative = k == 0 ? "Aujourd'hui" : (k > 0 ? "J+\(k)" : "J−\(-k)")
        guard let date = dayDate else { return relative }
        return "\(relative) · \(Self.format(iso: date))"
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

    // MARK: - Chargement

    /// Démarre (ou redémarre, si l'adresse de l'API a changé) : espèces, palette, manifeste des tuiles.
    func start(apiBaseURL: URL) async {
        if apiBaseURL != api.baseURL {
            api = ChampisAPI(baseURL: apiBaseURL)
            weather = WeatherField()
            weatherStatus = nil
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
            refreshWeather()
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Réglages

    func select(layerKey: LayerKey?) {
        selectedLayer = layers.first { $0.key == layerKey }
        pushSettings()
        refreshWeather()
    }

    func setDay(_ offset: Int) {
        dayOffset = min(max(offset, Self.dayRange.lowerBound), Self.dayRange.upperBound)
        pushSettings()
    }

    func setMode(_ mode: MapMode) {
        self.mode = mode
        pushSettings()
        refreshWeather()
    }

    func visibleRegionChanged(_ bbox: BBox) {
        visibleBBox = bbox
        refreshWeather(debounce: true)
    }

    func select(latitude: Double, longitude: Double) {
        selection = MapSelection(latitude: latitude, longitude: longitude)
    }

    func clearSelection() {
        selection = nil
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

    private func pushSettings() {
        renderer.update(RenderSettings(
            layer: selectedLayer,
            mode: mode,
            date: dayDate,
            weather: weather,
            colorizer: catalog.map { TileColorizer(palette: $0.palette) }
        ))
        renderGeneration += 1
    }
}
