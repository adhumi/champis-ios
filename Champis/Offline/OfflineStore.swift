import Foundation

/// Conteneur du hors ligne : `Application Support/Champis/offline/`, exclu de la sauvegarde iCloud.
/// `offline.json` liste les départements ; chaque département a son dossier (PMTiles, `weather.json`).
/// Les réponses `/species` et `/tiles` y sont aussi gardées pour démarrer sans réseau.
actor OfflineStore {
    let root: URL
    private var manifest = OfflineManifest()
    private var loaded = false

    init(root: URL) {
        self.root = root
    }

    static func defaultRoot() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let root = support.appending(path: "Champis/offline", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try DiskTileCache.excludeFromBackup(root)
        return root
    }

    private var manifestURL: URL { root.appending(path: "offline.json") }
    private var catalogURL: URL { root.appending(path: "species.json") }
    private var tilesManifestURL: URL { root.appending(path: "tiles.json") }

    func directory(for code: String) -> URL {
        root.appending(path: code, directoryHint: .isDirectory)
    }

    func fileURL(code: String, name: String) -> URL {
        directory(for: code).appending(path: name)
    }

    private func weatherURL(code: String) -> URL {
        directory(for: code).appending(path: "weather.json")
    }

    func load() throws {
        guard !loaded else { return }
        loaded = true
        manifest = try Self.read(OfflineManifest.self, at: manifestURL) ?? OfflineManifest()
    }

    var departments: [OfflineDepartment] {
        manifest.departments.values.sorted { $0.code < $1.code }
    }

    func department(_ code: String) -> OfflineDepartment? {
        manifest.departments[code]
    }

    // MARK: Téléchargement

    /// Enregistre l'intention : le département existe dans le manifeste, incomplet.
    func begin(_ department: OfflineDepartment) throws {
        try FileManager.default.createDirectory(at: directory(for: department.code), withIntermediateDirectories: true)
        manifest.departments[department.code] = department
        try save()
    }

    func markDone(code: String, name: String, bytes: Int64) throws {
        guard var department = manifest.departments[code],
              let index = department.files.firstIndex(where: { $0.name == name })
        else { return }
        department.files[index].done = true
        department.files[index].bytes = bytes
        department.error = nil
        manifest.departments[code] = department
        try save()
    }

    func markError(code: String, _ message: String) throws {
        guard var department = manifest.departments[code] else { return }
        department.error = message
        manifest.departments[code] = department
        try save()
    }

    /// Météo du département : les réponses `/weather/bbox` de ses sous-emprises, telles quelles.
    func saveWeather(code: String, responses: [WeatherBBoxResponse], fetchedAt: String) throws {
        guard var department = manifest.departments[code] else { return }
        let encoder = JSONEncoder()
        try encoder.encode(responses).write(to: weatherURL(code: code), options: .atomic)
        department.weatherToday = responses.first?.today
        department.weatherFetchedAt = fetchedAt
        department.error = nil
        manifest.departments[code] = department
        try save()
    }

    func weather(code: String) throws -> [WeatherBBoxResponse] {
        try Self.read([WeatherBBoxResponse].self, at: weatherURL(code: code)) ?? []
    }

    /// Toute la météo embarquée des départements complets, pour servir la carte sans réseau.
    func allWeather() -> [WeatherBBoxResponse] {
        departments.filter(\.complete).flatMap { (try? weather(code: $0.code)) ?? [] }
    }

    func remove(code: String) throws {
        manifest.departments[code] = nil
        try? FileManager.default.removeItem(at: directory(for: code))
        try save()
    }

    /// Fichiers des départements complets, à lire avant la source distante.
    func localFiles() -> [OfflineLocalFile] {
        departments.filter(\.complete).flatMap { department in
            department.files.map {
                OfflineLocalFile(kind: $0.kind, species: $0.species, url: fileURL(code: department.code, name: $0.name))
            }
        }
    }

    var totalBytes: Int64 {
        departments.reduce(0) { $0 + $1.bytes }
    }

    // MARK: Caches pour démarrer sans réseau

    func saveCatalog(_ catalog: SpeciesCatalog) throws {
        try write(catalog, to: catalogURL)
    }

    func cachedCatalog() -> SpeciesCatalog? {
        try? Self.read(SpeciesCatalog.self, at: catalogURL)
    }

    func saveTilesManifest(_ tiles: TilesManifest) throws {
        try write(tiles, to: tilesManifestURL)
    }

    func cachedTilesManifest() -> TilesManifest? {
        try? Self.read(TilesManifest.self, at: tilesManifestURL)
    }

    // MARK: Fichiers

    private func save() throws {
        try write(manifest, to: manifestURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}
