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

    /// Symbole de l'option dans le menu du bouton de fond de carte.
    var systemImage: String {
        switch self {
        case .standard: "map"
        case .satellite: "globe.europe.africa"
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

/// Dernière météo complète reçue : l'emprise demandée (avec marge), la couche, le jour et l'instant.
/// `day` nil pour `GET /weather/bbox` (les 11 jours d'un coup), le jour ISO pour un champ compact
/// `GET /weather/field`. Une emprise contenue dedans, pour la même couche et le même jour, est
/// déjà peinte : rien à demander.
nonisolated struct WeatherCoverage: Sendable {
    let bbox: BBox
    let layer: LayerKey
    let day: String?
    let at: Date
}

/// Un champ compact reçu : le jour et la couche.
nonisolated struct FieldCoverageKey: Hashable, Sendable {
    let day: String
    let layer: LayerKey
}

/// Ce que la carte demande pour la météo de l'emprise, selon le zoom (spec › Points ouverts ›
/// Carte visible dès l'ouverture, sous le zoom 9, décision du 4 nov. 2026).
nonisolated enum WeatherRequest: Hashable, Sendable {
    /// `/weather/bbox` : 11 jours, emprise bornée à 5 000 cellules, au zoom 9 et au-delà.
    case bbox
    /// `/weather/field` : le seul jour affiché, sans plafond de cellules, sous le zoom 9.
    case field(day: String)
}

/// Modèle de l'écran carte (MVVM, `@Observable`, MainActor). Les vues ne calculent rien : espèce
/// ou groupe courant, jour, mode T/S, météo chargée, indice par département (pour le bandeau des
/// jours), fiche du point touché, état de chargement. Les tuiles se lisent et se colorisent hors
/// du MainActor (`TileStore`, `TileRenderer`) ; le modèle leur pousse ses réglages. La vue France
/// (départements colorés sous le zoom 9) est retirée : la couche de tuiles reste visible à tout
/// zoom (spec › Points ouverts › Vue France et indice par département, 4 nov. 2026).
@Observable
final class MapModel {
    static let dayRange = -3...7
    /// Marge autour de l'emprise visible pour la météo (une cellule, comme la carte web). L'API
    /// sert la météo précalculée de toute l'emprise, à tout zoom (décision du 2 nov. 2026) :
    /// plus de « zoomez » sur un écran ordinaire, seulement au-delà de 5 000 cellules.
    static let weatherPaddingDegrees = 0.1
    /// Durée pendant laquelle une météo complète reçue dispense de redemander une emprise qu'elle
    /// contient (zoom avant, petit déplacement) ; au-delà, on redemande pour suivre la pré-chauffe
    /// et le passage de minuit.
    nonisolated static let weatherCoverageMaxAge: TimeInterval = 30 * 60
    /// Sous ce zoom, l'emprise dépasse les 5 000 cellules de `/weather/bbox` (la France entière en
    /// fait ≈ 20 000) : la carte demande le champ compact `/weather/field` du seul jour affiché,
    /// et change de jour en le redemandant (décision du 4 nov. 2026).
    nonisolated static let fieldZoom = 9.0
    /// Région d'ouverture de la carte (décision du 16 nov. 2026) : la dernière région vue, gardée
    /// sur l'appareil (`SavedMapRegion`), sinon la France métropolitaine entière, Corse comprise.
    static var initialRegion: MKCoordinateRegion {
        let saved = SavedMapRegion.initial(stored: SavedMapRegion.storedValue(in: UserDefaults.standard))
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: saved.latitude, longitude: saved.longitude),
            span: MKCoordinateSpan(latitudeDelta: saved.latitudeDelta, longitudeDelta: saved.longitudeDelta)
        )
    }

    /// Fin d'un déplacement de la carte : garde le centre et l'étendue de la région vue, rien
    /// d'autre, pour le lancement suivant. Une région non valide n'est pas gardée.
    static func rememberRegion(_ region: MKCoordinateRegion) {
        let saved = SavedMapRegion(
            latitude: region.center.latitude, longitude: region.center.longitude,
            latitudeDelta: region.span.latitudeDelta, longitudeDelta: region.span.longitudeDelta
        )
        saved?.save(in: UserDefaults.standard)
    }

    // Réglages
    private(set) var layers: [Layer] = []
    private(set) var selectedLayer: Layer?
    private(set) var dayOffset = 0
    private(set) var mode: MapMode = .score
    var basemap: Basemap = .standard
    /// Opacité du renderer : 1, l'alpha est dans la donnée depuis l'échelle linéaire (6 nov. 2026 :
    /// `Palette.scale`, alpha du pixel = score) ; le fond reste lisible là où le score est bas.
    var overlayOpacity = 1.0

    // État
    private(set) var catalog: SpeciesCatalog?
    private(set) var manifest: TilesManifest?
    private(set) var weather = WeatherField()
    /// Ce que la carte dit sous elle, seulement quand c'est utile (9 nov. 2026) : météo hors ligne,
    /// emprise trop grande, une part notable de l'emprise sans météo ou pas à jour. `nil` le reste
    /// du temps : le nombre de cellules et l'heure du précalcul ne disent rien à qui cueille.
    private(set) var weatherNotice: String?
    private(set) var isLoading = false
    private(set) var isLoadingWeather = false
    /// Erreur en clair de la carte (chargement, lecture d'un point, cache), avec sa reprise (étape B4).
    private(set) var problem: Problem?
    /// Météo de l'emprise indisponible, en clair ; la reprise redemande la météo.
    private(set) var weatherProblem: Problem?
    /// Hôte de l'API quand ce n'est pas l'officielle (réglage de développement) : l'app est alors en
    /// lecture seule, sans identifiant, et le dit en permanence sur la carte et dans les réglages
    /// (décision du 13 nov. 2026). `nil` avec l'API officielle.
    private(set) var customAPIHost: String?
    /// Zoom Web Mercator de la vue ; `nil` tant que la carte n'a pas donné sa première région.
    private(set) var zoom: Double?
    /// Incrémenté à chaque réglage poussé au rendu : la vue carte redessine les tuiles.
    private(set) var renderGeneration = 0

    // Indice par département (bandeau des jours) et limites des départements (département sous
    // le centre, noms pour l'écran hors ligne)
    private(set) var deptIndex: DeptIndex?
    private(set) var deptFeatures: [MKGeoJSONFeature] = []

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
    private(set) var pointFactors: [String: Double]?
    /// Ligne complète (`M`, `M_eff`, `Φ`) du point reçue par `GET /weather`, pour la fiche quand la
    /// carte n'avait que le champ compact (sous le zoom 9).
    private(set) var pointRow: WeatherRow?
    private(set) var factorsStatus: String?
    /// `GET /weather?cell=` du point a échoué : en clair, avec « Réessayer » dans la fiche (étape B4).
    private(set) var factorsProblem: Problem?
    /// Statut de la forêt au point (étape B5) : forêt publique de l'ONF ou sans doute privée ;
    /// `nil` hors ligne ou si le service de l'IGN ne répond pas (la fiche n'a alors pas de ligne).
    private(set) var pointForest: String?
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
    /// Noms des départements, du GeoJSON servi par l'API (écran hors ligne, proposition d'embarquer).
    private(set) var departmentNames: [String: String] = [:]
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private let renderer: TileRenderer
    @ObservationIgnored private let store: TileStore
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private(set) var api: ChampisAPI
    /// Hôte qui reçoit l'identifiant et les données privées (`ChampisAPI.trustedHost`).
    @ObservationIgnored private let trustedHost: String
    @ObservationIgnored private var visibleBBox: BBox?
    /// Couverture de la dernière réponse complète de `/weather/bbox` (les 11 jours).
    @ObservationIgnored private var weatherCoverage: WeatherCoverage?
    /// Couverture des champs compacts reçus, par jour ISO et couche : changer de jour ou de couche
    /// sous le zoom 9 ne redemande pas un champ déjà reçu pour cette emprise.
    @ObservationIgnored private var fieldCoverage: [FieldCoverageKey: WeatherCoverage] = [:]
    @ObservationIgnored private var weatherTask: Task<Void, Never>?
    @ObservationIgnored private var inspectTask: Task<Void, Never>?
    @ObservationIgnored private var isLoadingBoundaries = false
    /// Ce que « Réessayer » relance pour `problem`.
    @ObservationIgnored private var problemRetry: Retry?

    /// Ce que « Réessayer » relance (étape B4).
    nonisolated enum Retry: Equatable, Sendable {
        case load
        case inspect(latitude: Double, longitude: Double)
    }

    init(
        apiBaseURL: URL, session: URLSession = .shared, diskCache: DiskTileCache? = nil, fieldDirectory: URL? = nil,
        identity: IdentityProvider? = nil, offlineRoot: URL? = nil, downloads: DownloadManager? = nil,
        trustedHost: String = ChampisAPI.officialHost
    ) {
        // L'identifiant pseudonyme part avec toutes les requêtes à l'API (spec › Backoffice › Usage,
        // 8 nov. 2026) : le serveur en tire une empreinte par jour pour compter les appareils actifs.
        // Il n'est pas lu ici : le trousseau est une lecture synchrone, faite hors du fil principal
        // au démarrage (`start`, `FieldModel.resolveIdentity`).
        let api = ChampisAPI(baseURL: apiBaseURL, session: session, userID: nil, trustedHost: trustedHost)
        self.session = session
        self.trustedHost = trustedHost
        self.api = api
        let tileStore = TileStore(disk: diskCache)
        store = tileStore
        let tileRenderer = TileRenderer(store: tileStore)
        renderer = tileRenderer
        overlay = ScoreTileOverlay(renderer: tileRenderer)
        let directory = fieldDirectory ?? (try? LocalStore.defaultDirectory())
            ?? FileManager.default.temporaryDirectory.appending(path: "champis-field", directoryHint: .isDirectory)
        field = FieldModel(api: api, store: LocalStore(directory: directory), identity: identity ?? .system)
        let offlineRoot = offlineRoot ?? (try? OfflineStore.defaultRoot())
            ?? FileManager.default.temporaryDirectory.appending(path: "champis-offline", directoryHint: .isDirectory)
        let offlineModel = OfflineModel(api: api, store: OfflineStore(root: offlineRoot), downloads: downloads ?? DownloadManager())
        offlineModel.onLocalFilesChanged = { files in
            await tileStore.setLocalFiles(files)
        }
        offline = offlineModel
        customAPIHost = Self.customHost(of: api)
    }

    /// Hôte à nommer dans le bandeau de lecture seule ; `nil` pour l'API officielle.
    nonisolated static func customHost(of api: ChampisAPI) -> String? {
        api.isOfficial ? nil : (api.baseURL.host() ?? api.baseURL.absoluteString)
    }

    var palette: Palette? { catalog?.palette }
    var legend: [Palette.Threshold] { catalog?.palette.thresholds ?? [] }
    /// Seuil « bon » de la palette (notification et tendance des coins) ; `nil` tant que rien n'est chargé.
    var goodThreshold: Double? { palette?.thresholds.first { $0.label == "bon" }?.min }

    /// `today` de l'API, par la météo ou l'indice par département, selon ce qui est arrivé.
    var today: String? { weather.today ?? deptIndex?.today }

    /// Jour affiché (ISO) ; `nil` tant que l'API n'a rien dit.
    var dayDate: String? {
        guard let today, let date = try? CivilDate(iso: today) else { return nil }
        return date.adding(days: dayOffset).description
    }

    func speciesName(_ id: String) -> String {
        catalog?.species[id]?.names?.fr ?? id
    }

    /// Groupes du sélecteur d'espèce, avant le séparateur (9 nov. 2026).
    var groupLayers: [Layer] { layers.filter(\.isGroup) }

    /// Espèces seules du sélecteur, après le séparateur.
    var speciesLayers: [Layer] { layers.filter { !$0.isGroup } }

    /// Un message à montrer sous la carte : une erreur, ou une information qui change la lecture de
    /// la carte (`weatherNotice`). Sinon, rien sous la carte.
    var hasNotice: Bool {
        problem != nil || weatherProblem != nil || weatherNotice != nil
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
        await field.resolveIdentity()
        let moved = apiBaseURL != api.baseURL
        if moved || api.userID != field.userID {
            api = ChampisAPI(baseURL: apiBaseURL, session: session, userID: field.userID, trustedHost: trustedHost)
        }
        customAPIHost = Self.customHost(of: api)
        if moved {
            weather = WeatherField()
            weatherCoverage = nil
            fieldCoverage = [:]
            weatherNotice = nil
            deptIndex = nil
            deptFeatures = []
        }
        await load()
        await field.start(api: api)
        await offline.start(api: api)
    }

    func load() async {
        isLoading = true
        setProblem(nil)
        defer { isLoading = false }
        do {
            let (catalog, manifest) = try await fetchCatalogAndManifest()
            self.catalog = catalog
            self.manifest = manifest
            layers = LayerCatalog.layers(from: catalog)
            await store.configure(
                manifest: manifest, api: api, scoringVersion: ChampisScoring.supportedScoringVersion, palette: catalog.palette
            )
            if !manifest.configured {
                setProblem(
                    Problem("La carte n'est pas encore disponible : le serveur n'a pas de tuiles", detail: "GET /tiles : aucun jeu configuré"),
                    retry: .load
                )
            }
            if selectedLayer == nil || !layers.contains(where: { $0.key == selectedLayer?.key }) {
                selectedLayer = layers.first
            }
            pushSettings()
            refreshData()
        } catch {
            setProblem(Problem("Impossible de charger la carte", error: error), retry: .load)
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
            setProblem(
                Problem("Sans réseau : la carte montre ce qui a été chargé au dernier démarrage", detail: Problem.technical(error)),
                retry: .load
            )
            return (catalog, manifest)
        }
    }

    // MARK: - Réglages

    func select(layerKey: LayerKey?) {
        selectedLayer = layers.first { $0.key == layerKey }
        pushSettings()
        refreshData()
    }

    /// Au zoom 9 et au-delà, les 11 jours sont déjà là : rien à recharger. Sous le zoom 9, le champ
    /// compact du nouveau jour est demandé s'il ne l'a pas déjà été pour cette emprise.
    func setDay(_ offset: Int) {
        dayOffset = min(max(offset, Self.dayRange.lowerBound), Self.dayRange.upperBound)
        pushSettings()
        if usesWeatherField {
            refreshWeather()
        }
    }

    /// Vrai sous le zoom 9 : la météo de l'emprise vient du champ compact d'un seul jour.
    var usesWeatherField: Bool {
        zoom.map { $0 < Self.fieldZoom } ?? false
    }

    /// Le potentiel terrain seul (`.terrain`) n'est plus proposé sur la carte depuis le 9 nov. 2026 :
    /// la carte reste en score du jour. Le rendu de T seul demeure (fiche, tests du colorisateur).
    func setMode(_ mode: MapMode) {
        self.mode = mode
        pushSettings()
        refreshData()
    }

    /// Déplacement ou zoom : aucun réglage de rendu ne change (la couche de tuiles reste à tout
    /// zoom), seuls le département sous le centre et la météo de l'emprise sont à rafraîchir.
    func visibleRegionChanged(_ bbox: BBox, zoom: Double) {
        visibleBBox = bbox
        self.zoom = zoom
        centerDeptCode = departementCode(
            latitude: (bbox.minLat + bbox.maxLat) / 2, longitude: (bbox.minLon + bbox.maxLon) / 2
        )
        refreshData(debounce: true)
    }

    /// La météo de l'emprise, à tout zoom. L'indice par département ne se charge plus : le bandeau
    /// des jours, son seul lecteur, a quitté la carte (spec › Produit › étape A, 6 nov. 2026). Les
    /// limites des départements, elles, restent chargées une fois : elles nomment le département
    /// d'un nouveau coin pour la proposition d'embarquer.
    private func refreshData(debounce: Bool = false) {
        loadBoundariesIfNeeded()
        refreshWeather(debounce: debounce)
    }

    // MARK: - Météo

    /// Météo de l'emprise visible (avec marge) pour les espèces de la couche. Au zoom 9 et au-delà,
    /// `GET /weather/bbox` : les 11 jours arrivent d'un coup, le curseur de jour ne recharge rien.
    /// Sous le zoom 9, `GET /weather/field` : le champ compact du seul jour affiché, sans plafond de
    /// cellules ; les champs reçus se gardent par jour. Une emprise déjà couverte par la dernière
    /// réponse complète (zoom avant, petit déplacement, même jour) ne redemande rien.
    private func refreshWeather(debounce: Bool = false) {
        weatherTask?.cancel()
        guard mode == .score, let layer = selectedLayer, let bbox = visibleBBox, let zoom, catalog != nil else {
            weatherNotice = nil
            return
        }
        let requested = bbox.padded(by: Self.weatherPaddingDegrees)
        // Tant que l'API n'a pas dit son `today`, le jour de l'appareil ; la réponse le corrige.
        let request = Self.weatherRequest(zoom: zoom, day: dayDate ?? FieldModel.isoDay())
        let now = Date.now
        switch request {
        case .bbox:
            if Self.weatherAlreadyCovers(weatherCoverage, layer: layer.key, bbox: requested, day: nil, now: now) {
                // une couverture vient d'une réponse complète : rien à dire sous la carte
                weatherNotice = nil
                return
            }
        case .field(let day):
            if Self.weatherAlreadyCovers(weatherCoverage, layer: layer.key, bbox: requested, day: day, now: now)
                || Self.weatherAlreadyCovers(
                    fieldCoverage[FieldCoverageKey(day: day, layer: layer.key)], layer: layer.key, bbox: requested, day: day, now: now
                ) {
                weatherNotice = nil
                return
            }
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
                switch request {
                case .bbox:
                    let response = try await api.weather(bbox: requested, species: layer.members)
                    guard !Task.isCancelled else { return }
                    forgetCoverageIfNewDay(response.today)
                    weather.merge(response)
                    weatherNotice = Self.notice(for: response)
                    weatherProblem = nil
                    weatherCoverage = Self.isComplete(response)
                        ? WeatherCoverage(bbox: requested, layer: layer.key, day: nil, at: .now) : nil
                    pushSettings()
                case .field(let day):
                    let response = try await api.weatherField(bbox: requested, species: layer.members, day: day)
                    guard !Task.isCancelled else { return }
                    forgetCoverageIfNewDay(response.today)
                    weather.merge(response)
                    weatherNotice = Self.notice(for: response)
                    weatherProblem = nil
                    fieldCoverage[FieldCoverageKey(day: day, layer: layer.key)] = Self.isComplete(response)
                        ? WeatherCoverage(bbox: requested, layer: layer.key, day: day, at: .now) : nil
                    pushSettings()
                    // Le jour venait de l'horloge de l'appareil et l'API compte autrement : le bon jour.
                    if let current = dayDate, current != day {
                        refreshWeather()
                    }
                }
            } catch let failure as ChampisAPI.Failure {
                guard !Task.isCancelled else { return }
                weatherCoverage = nil
                if case .http(let status, let detail) = failure, status == 422 {
                    let fallback = request == .bbox ? "Zoomez pour afficher la météo" : "Jour hors de la fenêtre météo"
                    weatherNotice = detail.isEmpty ? fallback : detail
                    weatherProblem = nil
                } else {
                    await useOfflineWeather(or: Problem("Météo indisponible", error: failure))
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                weatherCoverage = nil
                await useOfflineWeather(or: Problem("Météo indisponible", error: error))
            }
        }
    }

    /// Minuit passé côté API : `WeatherField` jette ses cellules, les couvertures ne valent plus.
    private func forgetCoverageIfNewDay(_ today: String) {
        if weather.today != today {
            weatherCoverage = nil
            fieldCoverage = [:]
        }
    }

    /// Attend la fin de la requête météo en cours (et de celle qu'elle relance, le cas échéant) :
    /// pour les tests, la vue observe `isLoadingWeather`.
    func awaitWeather() async {
        while let task = weatherTask {
            await task.value
            if weatherTask == task { return }
        }
    }

    /// `/weather/bbox` au zoom 9 et au-delà, le champ compact du jour en dessous. Fonction pure, testée.
    nonisolated static func weatherRequest(zoom: Double, day: String) -> WeatherRequest {
        zoom < fieldZoom ? .field(day: day) : .bbox
    }

    /// Vrai si la dernière météo complète reçue couvre déjà `bbox` pour cette couche et ce jour
    /// (`day` nil : les 11 jours de `/weather/bbox`, qu'une couverture d'un seul jour ne remplace pas ;
    /// une couverture des 11 jours vaut pour tout jour) et n'a pas dépassé `weatherCoverageMaxAge`.
    /// Fonction pure, testée sans réseau.
    nonisolated static func weatherAlreadyCovers(
        _ coverage: WeatherCoverage?, layer: LayerKey, bbox: BBox, day: String?, now: Date
    ) -> Bool {
        guard let coverage, coverage.layer == layer else { return false }
        guard coverage.day == nil || coverage.day == day else { return false }
        guard now.timeIntervalSince(coverage.at) < weatherCoverageMaxAge else { return false }
        return coverage.bbox.contains(bbox)
    }

    /// Une réponse complète ne manque d'aucune cellule et ne vient pas d'un cache périmé : on peut
    /// s'en contenter un moment. Sinon, le prochain déplacement redemande.
    nonisolated static func isComplete(_ response: WeatherBBoxResponse) -> Bool {
        response.unavailable.isEmpty && !response.cells.contains { $0.stale }
    }

    nonisolated static func isComplete(_ response: WeatherFieldResponse) -> Bool {
        response.unavailable == 0 && !response.anyStale
    }

    /// Sans réseau : la météo embarquée des départements complets, avec sa date affichée en clair.
    /// Rien d'inventé : un pixel hors de ces départements reste transparent.
    private func useOfflineWeather(or problem: Problem) async {
        let snapshots = await offline.offlineWeather()
        guard !snapshots.isEmpty else {
            weatherNotice = nil
            weatherProblem = problem
            return
        }
        weatherProblem = nil
        for response in snapshots {
            weather.merge(response)
        }
        weatherNotice = "Hors ligne : météo du \(Self.format(iso: weather.today ?? ""))"
        pushSettings()
    }

    /// Part de l'emprise (cellules servies et manquantes) au-delà de laquelle des cellules sans météo,
    /// ou servies depuis un précalcul périmé, se disent sous la carte. En deçà, quelques cellules au
    /// bord de l'écran ne valent pas un message permanent.
    nonisolated static let noticeShare = 0.25

    /// Message sous la carte pour une réponse météo, ou `nil` s'il n'y a rien d'utile à dire. Sans
    /// météo, un pixel est transparent : à ne pas lire comme un mauvais score, d'où le message.
    /// Fonction pure, testée.
    nonisolated static func notice(cells: Int, stale: Int, missing: Int) -> String? {
        let total = Double(cells + missing)
        guard total > 0 else { return nil }
        if Double(missing) >= noticeShare * total {
            return "Pas de météo sur une partie de la carte : ces zones restent transparentes."
        }
        if Double(stale) >= noticeShare * total {
            return "Météo pas à jour sur une partie de la carte : le score peut y être décalé."
        }
        return nil
    }

    nonisolated static func notice(for response: WeatherBBoxResponse) -> String? {
        notice(cells: response.cells.count, stale: response.cells.count { $0.stale }, missing: response.unavailable.count)
    }

    nonisolated static func notice(for response: WeatherFieldResponse) -> String? {
        notice(cells: response.cells.count, stale: response.cells.count { $0.stale }, missing: response.unavailable)
    }

    // MARK: - Limites des départements (proposition d'embarquer)

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
                // sans limites : bandeau sans indice, pas de proposition d'embarquer ; rien d'inventé
                return
            }
        }
    }

    // MARK: - Fiche au toucher

    func select(latitude: Double, longitude: Double) {
        selection = MapSelection(latitude: latitude, longitude: longitude)
        inspectTask?.cancel()
        pointFactors = nil
        pointRow = nil
        factorsStatus = nil
        factorsProblem = nil
        pointForest = nil
        if case .inspect? = problemRetry {
            setProblem(nil)
        }
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
                setProblem(Problem("Ce point n'a pas pu être lu", error: error), retry: .inspect(latitude: latitude, longitude: longitude))
            }
        }
    }

    /// Facteurs météo du point (`GET /weather?cell=&species=`), pour la fiche.
    func loadFactors(for info: PointInfo) async {
        guard case .scored(let scored) = info.outcome, let cell = scored.cell, let date = info.date,
              let altKey = scored.altKey
        else { return }
        factorsStatus = nil
        factorsProblem = nil
        do {
            let detail = try await api.weatherDetail(cell: cell.id, species: [scored.species])
            let rows = detail.species[scored.species] ?? []
            let row = rows.first { $0.date == date }?.byAlt[altKey]
            pointRow = row
            pointFactors = row?.factors
            pointSummary = row?.summary
            // les onze jours suivent la carte : interpolés quand les cellules voisines ont le jour
            // (/weather/bbox), sinon ceux de la cellule du point
            let sample = weather.sample(lat: info.latitude, lon: info.longitude)
            let palette = palette
            pointDays = Self.pointDays(rows: rows, altKey: altKey, terrain: scored.terrain, species: scored.species) { day in
                guard let sample, let palette else { return nil }
                return sample.factor(species: scored.species, date: day, index: scored.altIndex, palette: palette)
            }
            if pointFactors == nil {
                factorsStatus = "Facteurs indisponibles pour ce jour."
            }
        } catch {
            factorsProblem = Problem("Météo de ce point indisponible", error: error)
        }
    }

    /// Statut de la forêt au point touché (étape B5, 6 nov. 2026) : la couche ONF des forêts
    /// publiques, interrogée à l'ouverture de la fiche par le WFS de l'IGN. En ligne seulement :
    /// sans réponse, rien ne s'affiche (jamais « privée » par défaut faute de réseau).
    func loadForest(for info: PointInfo) async {
        guard !info.isNoData, let url = PublicForest.url(latitude: info.latitude, longitude: info.longitude) else { return }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let phrase = try PublicForest.phrase(from: data)
            // un autre point a pu être touché entre-temps
            guard pointInfo?.id == info.id else { return }
            pointForest = phrase
        } catch {
            return
        }
    }

    /// `T × M_eff × Φ` pour chacun des jours renvoyés par l'API, à la classe d'altitude du pixel.
    /// `interpolated` donne `M_eff × Φ` interpolé entre cellules pour un jour (`nil` si inconnu :
    /// le jour prend alors la valeur de la cellule du point).
    nonisolated static func pointDays(
        rows: [WeatherDay], altKey: String, terrain: Double, species: String,
        interpolated: (String) -> Double? = { _ in nil }
    ) -> [CoinDay] {
        rows.map { day in
            let factor = interpolated(day.date) ?? day.byAlt[altKey]?.factor
            return CoinDay(date: day.date, value: factor.map { terrain * $0 }, leading: factor == nil ? nil : species)
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
        pointRow = nil
        pointSummary = nil
        pointDays = []
        factorsStatus = nil
        factorsProblem = nil
        pointForest = nil
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
        // l'altitude du pixel quand la couche E la donne (le backend interpole entre deux classes),
        // sinon le centre de sa classe
        let altClass = scored.altitudeM.map { Int($0) }
            ?? scored.altClass.map { $0 * classM + classM / 2 } ?? scored.altKey.flatMap { Int($0) } ?? 0
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
        let species = choice.species
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

    // MARK: - Erreurs en clair (étape B4)

    private func setProblem(_ problem: Problem?, retry: Retry? = nil) {
        self.problem = problem
        problemRetry = problem == nil ? nil : retry
    }

    /// « Réessayer » sous un message de la carte.
    func retryProblem() {
        let retry = problemRetry
        setProblem(nil)
        switch retry {
        case .load:
            Task { await load() }
        case .inspect(let latitude, let longitude):
            select(latitude: latitude, longitude: longitude)
        case nil:
            break
        }
    }

    /// « Réessayer » sous le message de météo.
    func retryWeather() {
        weatherProblem = nil
        weatherCoverage = nil
        refreshWeather()
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
            setProblem(Problem("Le cache n'a pas pu être vidé", error: error, retryable: false))
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
