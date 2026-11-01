import ChampisPMTiles
import ChampisScoring
import CoreLocation
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

/// Point touché sur la carte. `Identifiable` par ses coordonnées : une feuille par point (lot 3).
nonisolated struct MapSelection: Hashable, Identifiable, Sendable {
    let latitude: Double
    let longitude: Double
    var id: MapSelection { self }
}

/// Une pastille du bandeau des jours (lot 2).
nonisolated struct DayDot: Identifiable, Hashable, Sendable {
    let offset: Int
    let date: String?
    let value: Double?
    var id: Int { offset }
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
    /// Appui long sur la carte (lot 3) : le point pressé, à proposer en menu de terrain.
    private(set) var longPressPoint: MapSelection?
    /// Après un appui long « Ajouter à mes coins » : la fiche inspectée sert à nommer le coin.
    private(set) var coinRequestFromLongPress = false
    /// Proposition d'embarquer un département après la création d'un coin (lot 3).
    private(set) var offlineSuggestion: DownloadableDepartment?
    private(set) var pointInfo: PointInfo?
    private(set) var isInspecting = false
    private(set) var inspectError: String?
    private(set) var pointFactors: [String: Double]?
    private(set) var factorsStatus: String?
    /// Phrases en clair de `GET /weather` › `summary` pour le point (lot 2).
    private(set) var pointSummary: [String]?
    /// Les onze jours du point : `T × M_eff × Φ` par jour pour l'espèce porteuse (lot 2).
    private(set) var pointDays: [CoinDay] = []
    /// Département sous le centre de la carte, pour colorer le bandeau des jours (lot 2).
    private(set) var centerDeptCode: String?

    // Position et cache
    /// Incrémenté quand l'utilisateur demande à centrer la carte sur lui.
    private(set) var followRequest = 0
    /// Demande de recentrage sur un point (un coin ouvert depuis Mes coins) : (numéro, coordonnée).
    private(set) var focusRequest: (id: Int, latitude: Double, longitude: Double)?
    private(set) var tileCacheSize: Int64?

    let overlay: ScoreTileOverlay
    /// Observations et coins (skill `field-feedback`).
    let field: FieldModel
    /// Départements embarqués (skill `offline`).
    let offline: OfflineModel
    /// Noms des départements, du GeoJSON servi par l'API (vue France, écran hors ligne).
    private(set) var departmentNames: [String: String] = [:]
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private let renderer: TileRenderer
    @ObservationIgnored private let store: TileStore
    @ObservationIgnored private(set) var api: ChampisAPI
    @ObservationIgnored private var visibleBBox: BBox?
    @ObservationIgnored private var weatherTask: Task<Void, Never>?
    @ObservationIgnored private var deptTask: Task<Void, Never>?
    @ObservationIgnored private var deptTaskKey: LayerKey?
    @ObservationIgnored private var inspectTask: Task<Void, Never>?
    @ObservationIgnored private var isLoadingBoundaries = false

    init(
        apiBaseURL: URL, diskCache: DiskTileCache? = nil, fieldDirectory: URL? = nil,
        identityStores: [any IdentityStore]? = nil, offlineRoot: URL? = nil, downloads: DownloadManager? = nil
    ) {
        let api = ChampisAPI(baseURL: apiBaseURL)
        self.api = api
        let tileStore = TileStore(disk: diskCache)
        store = tileStore
        let tileRenderer = TileRenderer(store: tileStore)
        renderer = tileRenderer
        overlay = ScoreTileOverlay(renderer: tileRenderer)
        let directory = fieldDirectory ?? (try? LocalStore.defaultDirectory())
            ?? FileManager.default.temporaryDirectory.appending(path: "champis-field", directoryHint: .isDirectory)
        field = FieldModel(
            api: api, store: LocalStore(directory: directory),
            identityStores: identityStores ?? [KeychainIdentityStore(), DefaultsIdentityStore()]
        )
        let offlineRoot = offlineRoot ?? (try? OfflineStore.defaultRoot())
            ?? FileManager.default.temporaryDirectory.appending(path: "champis-offline", directoryHint: .isDirectory)
        let offlineModel = OfflineModel(api: api, store: OfflineStore(root: offlineRoot), downloads: downloads ?? DownloadManager())
        offlineModel.onLocalFilesChanged = { files in
            await tileStore.setLocalFiles(files)
        }
        offline = offlineModel
    }

    var palette: Palette? { catalog?.palette }
    var legend: [Palette.Threshold] { catalog?.palette.thresholds ?? [] }
    /// Seuil « bon » de la palette (notification et tendance des coins) ; `nil` tant que rien n'est chargé.
    var goodThreshold: Double? { palette?.thresholds.first { $0.label == "bon" }?.min }
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

    /// Espèces du catalogue pour un sélecteur, par nom français.
    var speciesOptions: [SpeciesOption] {
        (catalog?.species ?? [:])
            .map { SpeciesOption(id: $0.key, name: $0.value.names?.fr ?? $0.key) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Libellé d'une cible de coin (identifiant d'espèce ou de groupe tel que l'API l'attend).
    func layerTitle(forTarget target: String) -> String {
        layers.first { Self.apiTarget($0.key) == target }?.title ?? speciesName(target)
    }

    /// Identifiant d'espèce ou de groupe, sans préfixe : ce que `PUT /coins` attend dans `target`.
    static func apiTarget(_ key: LayerKey) -> String {
        switch key {
        case .species(let id): id
        case .group(let id): id
        }
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
        await field.start(api: api)
        await offline.start(api: api)
    }

    func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let (catalog, manifest) = try await fetchCatalogAndManifest()
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

    /// `/species` et `/tiles` ; sans réseau, les réponses du dernier démarrage gardées pour le hors ligne.
    private func fetchCatalogAndManifest() async throws -> (SpeciesCatalog, TilesManifest) {
        do {
            let catalog = try await api.species()
            let manifest = try await api.tiles()
            try? await offline.store.saveCatalog(catalog)
            try? await offline.store.saveTilesManifest(manifest)
            return (catalog, manifest)
        } catch {
            guard let catalog = await offline.store.cachedCatalog(),
                  let manifest = await offline.store.cachedTilesManifest()
            else { throw error }
            loadError = "Hors ligne : espèces et tuiles du dernier démarrage."
            return (catalog, manifest)
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
        centerDeptCode = departementCode(
            latitude: (bbox.minLat + bbox.maxLat) / 2, longitude: (bbox.minLon + bbox.maxLon) / 2
        )
        refreshData(debounce: true)
    }

    /// L'indice par département sert à tout zoom (bandeau des jours, lot 2) ; la météo de l'emprise
    /// seulement sous le zoom seuil.
    private func refreshData(debounce: Bool = false) {
        refreshDeptIndex()
        if isFranceView {
            weatherTask?.cancel()
        } else {
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
                    await useOfflineWeather(or: "Météo indisponible : \(failure.localizedDescription)")
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await useOfflineWeather(or: "Météo indisponible : \(error.localizedDescription)")
            }
        }
    }

    /// Sans réseau : la météo embarquée des départements complets, avec sa date affichée en clair.
    /// Rien d'inventé : un pixel hors de ces départements reste transparent.
    private func useOfflineWeather(or message: String) async {
        let snapshots = await offline.offlineWeather()
        guard !snapshots.isEmpty else {
            weatherStatus = message
            return
        }
        for response in snapshots {
            weather.merge(response)
        }
        weatherStatus = "Hors ligne : météo du \(Self.format(iso: weather.today ?? ""))"
        pushSettings()
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
        guard mode == .score, let layer = selectedLayer, catalog != nil else { return }
        if deptFeatures.isEmpty {
            loadBoundaries()
        }
        if let deptIndex, deptIndex.layerKey == layer.key {
            return
        }
        if deptTask != nil, deptTaskKey == layer.key {
            return  // déjà en cours pour cette couche
        }
        deptTaskKey = layer.key
        deptTask?.cancel()
        let api = api
        deptTask = Task { [weak self] in
            guard let self else { return }
            defer { deptTaskKey = nil }
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

    func loadBoundariesIfNeeded() {
        if deptFeatures.isEmpty {
            loadBoundaries()
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
                var names: [String: String] = [:]
                for feature in deptFeatures {
                    guard let properties = feature.properties,
                          let dict = try? JSONSerialization.jsonObject(with: properties) as? [String: Any],
                          let code = dict["code"] as? String, let name = dict["nom"] as? String
                    else { continue }
                    names[code] = name
                }
                departmentNames = names
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
            let rows = detail.species[scored.species] ?? []
            let row = rows.first { $0.date == date }?.byAlt[altKey]
            pointFactors = row?.factors
            pointSummary = row?.summary
            pointDays = Self.pointDays(rows: rows, altKey: altKey, terrain: scored.terrain, species: scored.species)
            if pointFactors == nil {
                factorsStatus = "Facteurs indisponibles pour ce jour."
            }
        } catch {
            factorsStatus = "Facteurs indisponibles : \(error.localizedDescription)"
        }
    }

    /// `T × M_eff × Φ` pour chacun des jours renvoyés par l'API, à la classe d'altitude du pixel.
    nonisolated static func pointDays(rows: [WeatherDay], altKey: String, terrain: Double, species: String) -> [CoinDay] {
        rows.map { day in
            let row = day.byAlt[altKey]
            return CoinDay(date: day.date, value: row.map { terrain * $0.factor }, leading: row == nil ? nil : species)
        }
    }

    /// Jour ISO pour un décalage de `offset` jours autour de `today` ; `nil` sans `today`.
    func date(forOffset offset: Int) -> String? {
        guard let today, let date = try? CivilDate(iso: today) else { return nil }
        return date.adding(days: offset).description
    }

    /// Les onze pastilles du bandeau des jours : décalage, jour ISO et indice du département sous
    /// le centre (`nil` sans indice : pastille vide, jamais une valeur inventée).
    var dayDots: [DayDot] {
        Self.dayRange.map { k in
            let iso = date(forOffset: k)
            var value: Double?
            if let iso, let code = centerDeptCode {
                value = deptIndex?.value(code: code, date: iso)
            }
            return DayDot(offset: k, date: iso, value: value)
        }
    }

    /// Département contenant une coordonnée, par les limites déjà chargées (`/web/departements.geojson`).
    func departementCode(latitude: Double, longitude: Double) -> String? {
        let point = MKMapPoint(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        for feature in deptFeatures {
            guard let properties = feature.properties,
                  let dict = try? JSONSerialization.jsonObject(with: properties) as? [String: Any],
                  let code = dict["code"] as? String
            else { continue }
            for shape in feature.geometry {
                if let polygon = shape as? MKPolygon, Self.contains(point, in: polygon) {
                    return code
                }
                if let multi = shape as? MKMultiPolygon, multi.polygons.contains(where: { Self.contains(point, in: $0) }) {
                    return code
                }
            }
        }
        return nil
    }

    /// Point dans polygone par lancer de rayon, sur les points carte du polygone (trous ignorés).
    nonisolated static func contains(_ point: MKMapPoint, in polygon: MKPolygon) -> Bool {
        guard polygon.boundingMapRect.contains(point) else { return false }
        let points = polygon.points()
        return contains(point, ring: (0..<polygon.pointCount).map { points[$0] })
    }

    nonisolated static func contains(_ point: MKMapPoint, ring: [MKMapPoint]) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > point.y) != (b.y > point.y) {
                let x = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
                if point.x < x {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }

    func clearSelection() {
        coinRequestFromLongPress = false
        inspectTask?.cancel()
        selection = nil
        pointInfo = nil
        pointFactors = nil
        pointSummary = nil
        pointDays = []
        factorsStatus = nil
    }

    // MARK: - Position et cache

    // MARK: - Terrain en deux tapes (lot 3)

    func longPress(latitude: Double, longitude: Double) {
        longPressPoint = MapSelection(latitude: latitude, longitude: longitude)
    }

    func clearLongPress() {
        longPressPoint = nil
    }

    /// « Ajouter à mes coins » depuis l'appui long : inspecter le point, puis nommer le coin.
    func requestCoin(latitude: Double, longitude: Double) {
        coinRequestFromLongPress = true
        select(latitude: latitude, longitude: longitude)
    }

    func clearCoinRequest() {
        coinRequestFromLongPress = false
    }

    /// Espèces du calque affiché : une observation « rien trouvé » par espèce (un groupe = toutes).
    var layerSpecies: [String] {
        selectedLayer?.members ?? []
    }

    /// Ce qu'un coin garde d'un point inspecté : la cible de la couche, la classe d'altitude du
    /// pixel et le T de chaque espèce (le backend n'a que la météo). `nil` hors forêt.
    func coinParameters(for info: PointInfo) -> (target: String, altClass: Int, t: [String: Double])? {
        guard let scored = info.scored else { return nil }
        let target = selectedLayer.map { Self.apiTarget($0.key) } ?? scored.species
        let classM = Int(palette?.altEncoding.classM ?? 300)
        let altClass = scored.altClass.map { $0 * classM + classM / 2 } ?? scored.altKey.flatMap { Int($0) } ?? 0
        let terrains = scored.terrains.isEmpty ? [scored.species: scored.terrain] : scored.terrains
        return (target, altClass, terrains)
    }

    /// Crée le coin depuis sa fiche, la ferme, et propose une fois d'embarquer son département s'il
    /// ne l'est pas. La proposition vient avant l'envoi au serveur : en forêt, il peut être long.
    func addCoin(named name: String, from info: PointInfo) async {
        guard let parameters = coinParameters(for: info) else { return }
        clearSelection()
        if let code = departementCode(latitude: info.latitude, longitude: info.longitude) {
            let suggestion = Self.suggestOffline(
                code: code, manifest: manifest, names: departmentNames,
                embarked: Set(offline.departments.map(\.code)), declined: Self.declinedOfflineDepts
            )
            if suggestion != nil {
                // le temps que la feuille se ferme, sinon l'alerte tombe sur une présentation en cours
                try? await Task.sleep(for: .milliseconds(400))
                offlineSuggestion = suggestion
            }
        }
        await field.addCoin(
            name: name, latitude: info.latitude, longitude: info.longitude, target: parameters.target,
            altClass: parameters.altClass, t: parameters.t
        )
    }

    /// Le jeu par département à proposer, ou `nil` : déjà embarqué, déjà refusé, ou pas publié.
    nonisolated static func suggestOffline(
        code: String, manifest: TilesManifest?, names: [String: String], embarked: Set<String>, declined: Set<String>
    ) -> DownloadableDepartment? {
        guard let manifest, !embarked.contains(code), !declined.contains(code) else { return nil }
        return OfflineModel.downloadable(from: manifest, names: names).first { $0.code == code }
    }

    nonisolated static let declinedOfflineKey = "offlineDeclinedDepartments"

    /// Départements pour lesquels la proposition a été refusée : jamais redemandés.
    nonisolated static var declinedOfflineDepts: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: declinedOfflineKey) ?? [])
    }

    /// Accepte la proposition : toutes les espèces du jeu, pour que le calque puisse changer en forêt.
    func acceptOfflineSuggestion() {
        guard let choice = offlineSuggestion, let manifest else { return }
        offlineSuggestion = nil
        let species = choice.terrain.keys.sorted()
        let version = catalog?.scoringVersion ?? ""
        let offline = offline
        Task { await offline.download(choice, species: species, manifest: manifest, scoringVersion: version) }
    }

    func declineOfflineSuggestion() {
        guard let choice = offlineSuggestion else { return }
        offlineSuggestion = nil
        var declined = Self.declinedOfflineDepts
        declined.insert(choice.code)
        UserDefaults.standard.set(Array(declined).sorted(), forKey: Self.declinedOfflineKey)
    }

    /// Recentre la carte sur un coin et sélectionne le point, depuis Mes coins › Voir sur la carte.
    func focus(latitude: Double, longitude: Double) {
        focusRequest = (id: (focusRequest?.id ?? 0) + 1, latitude: latitude, longitude: longitude)
        select(latitude: latitude, longitude: longitude)
    }

    /// Recentre sans ouvrir de fiche : la barre latérale montre déjà celle du coin (lot 3).
    func center(latitude: Double, longitude: Double) {
        focusRequest = (id: (focusRequest?.id ?? 0) + 1, latitude: latitude, longitude: longitude)
    }

    /// Position « pendant l'utilisation » seulement (skill `offline`) : demandée au premier appui,
    /// jamais au lancement ; aucun trajet n'est enregistré.
    func locateMe() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        followRequest += 1
    }

    var locationDenied: Bool {
        switch locationManager.authorizationStatus {
        case .denied, .restricted: true
        default: false
        }
    }

    func refreshTileCacheSize() async {
        tileCacheSize = await store.diskSize()
    }

    func clearTileCache() async {
        do {
            try await store.clearDisk()
        } catch {
            loadError = "Cache impossible à vider : \(error.localizedDescription)"
        }
        await refreshTileCacheSize()
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
