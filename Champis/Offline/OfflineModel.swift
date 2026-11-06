import ChampisPMTiles
import Foundation
import Observation

/// Un département proposé au téléchargement, d'après le manifeste `GET /tiles` (entrées `dept`).
nonisolated struct DownloadableDepartment: Identifiable, Hashable, Sendable {
    let code: String
    let name: String?
    /// Espèce → entrée `T` du manifeste.
    let terrain: [String: TilesManifest.Entry]
    /// Entrées `G` du département (un canal par espèce), triées par nom.
    let groups: [TilesManifest.Entry]
    let altitude: TilesManifest.Entry?

    init(code: String, name: String?, terrain: [String: TilesManifest.Entry], groups: [TilesManifest.Entry] = [], altitude: TilesManifest.Entry?) {
        self.code = code
        self.name = name
        self.terrain = terrain
        self.groups = groups
        self.altitude = altitude
    }

    var id: String { code }
    var title: String { name.map { "\($0) (\(code))" } ?? "Département \(code)" }

    /// Espèces proposées : celles qui ont un `T` ou un canal dans un `G`, triées.
    var species: [String] {
        Set(terrain.keys).union(groups.flatMap { $0.channels ?? [] }).sorted()
    }

    /// Fichiers à embarquer pour des espèces (spec › Points ouverts › Les clients lisent les PMTiles
    /// par groupe, 5 nov. 2026) : le `G` de chaque groupe touché, le `T` des seules espèces sans `G`,
    /// et `A`. Un `G` porte tout son groupe, même si une seule de ses espèces est choisie.
    func files(for species: [String]) -> [TilesManifest.Entry] {
        let wanted = Set(species)
        var out: [TilesManifest.Entry] = []
        var covered: Set<String> = []
        for group in groups where !wanted.isDisjoint(with: group.channels ?? []) {
            out.append(group)
            covered.formUnion(group.channels ?? [])
        }
        for sid in species.sorted() where !covered.contains(sid) {
            if let entry = terrain[sid] {
                out.append(entry)
            }
        }
        if let altitude {
            out.append(altitude)
        }
        return out
    }

    /// Taille annoncée = somme des fichiers retenus.
    func bytes(for species: [String]) -> Int64 {
        Int64(files(for: species).reduce(0) { $0 + ($1.bytes ?? 0) })
    }
}

/// Hors ligne par département (skill `offline`) : téléchargement atomique (tuiles de chaque espèce
/// choisie, couche A, météo des 11 jours sur l'emprise), liste des départements embarqués, mise à
/// jour de la météo seule, suppression. Déclenché par l'utilisateur, jamais automatiquement.
@Observable
final class OfflineModel {
    nonisolated struct Progress: Hashable, Sendable {
        var filesDone = 0
        var filesTotal = 0
        var bytesWritten: Int64 = 0
        var bytesExpected: Int64 = 0
        var fetchingWeather = false

        var fraction: Double {
            guard bytesExpected > 0 else { return filesTotal == 0 ? 0 : Double(filesDone) / Double(filesTotal) }
            return min(1, Double(bytesWritten) / Double(bytesExpected))
        }
    }

    /// Côté maximal d'une sous-emprise météo, en degrés (≈ 6 × 4 cellules de 5 km : des réponses
    /// courtes, qu'un téléchargement interrompu reprend sans tout refaire).
    static let weatherSpan = 0.3

    private(set) var departments: [OfflineDepartment] = []
    private(set) var progress: [String: Progress] = [:]
    /// Information en clair (« Rien à télécharger ») ; les échecs vont dans `problem`.
    private(set) var status: String?
    /// Échec en clair avec sa reprise (étape B4, 6 nov. 2026).
    private(set) var problem: Problem?
    private(set) var totalBytes: Int64 = 0

    @ObservationIgnored let store: OfflineStore
    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private(set) var api: ChampisAPI
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var written: [String: [String: Int64]] = [:]
    /// Appelé quand la liste des fichiers lisibles hors ligne change (le lecteur de tuiles s'y branche).
    @ObservationIgnored var onLocalFilesChanged: (@MainActor ([OfflineLocalFile]) async -> Void)?
    /// Ce que « Réessayer » relance pour `problem`.
    @ObservationIgnored private var problemRetry: Retry?

    /// Ce que « Réessayer » relance (étape B4).
    nonisolated enum Retry: Equatable, Sendable {
        case start
        case resume(code: String)
        case delete(code: String)
    }

    init(api: ChampisAPI, store: OfflineStore, downloads: DownloadManager) {
        self.api = api
        self.store = store
        self.downloads = downloads
    }

    func start(api: ChampisAPI) async {
        self.api = api
        do {
            try await store.load()
        } catch {
            fail(Problem("La liste des départements embarqués n'a pas pu être lue", error: error), retry: .start)
        }
        await refresh()
        await publishLocalFiles()
        if eventTask == nil {
            eventTask = Task { [weak self] in
                guard let self else { return }
                for await event in downloads.events {
                    await handle(event)
                }
            }
        }
    }

    private func refresh() async {
        departments = await store.departments
        totalBytes = await store.totalBytes
    }

    private func publishLocalFiles() async {
        let files = await store.localFiles()
        await onLocalFilesChanged?(files)
    }

    // MARK: Choix

    /// Départements du manifeste ayant un jeu propre (`dept`), avec les noms connus.
    nonisolated static func downloadable(from manifest: TilesManifest, names: [String: String]) -> [DownloadableDepartment] {
        var byCode: [String: (terrain: [String: TilesManifest.Entry], groups: [TilesManifest.Entry], altitude: TilesManifest.Entry?)] = [:]
        for entry in manifest.tiles {
            guard let dept = entry.dept else { continue }
            var current = byCode[dept] ?? ([:], [], nil)
            if entry.kind == "T", let species = entry.species {
                current.terrain[species] = entry
            } else if entry.kind == "G", let channels = entry.channels, !channels.isEmpty {
                current.groups.append(entry)
            } else if entry.kind == "A" {
                current.altitude = entry
            }
            byCode[dept] = current
        }
        return byCode
            .map {
                DownloadableDepartment(
                    code: $0.key, name: names[$0.key], terrain: $0.value.terrain,
                    groups: $0.value.groups.sorted { $0.name < $1.name }, altitude: $0.value.altitude
                )
            }
            .sorted { $0.code < $1.code }
    }

    // MARK: Téléchargement

    /// Lance le téléchargement d'un département pour les espèces choisies (`G` des groupes touchés,
    /// `T` des espèces sans `G`, couche `A` : `DownloadableDepartment.files`) ; rien n'est marqué
    /// disponible tant que tuiles, couche A et météo ne sont pas tous écrits.
    func download(_ choice: DownloadableDepartment, species: [String], manifest: TilesManifest, scoringVersion: String) async {
        var files: [OfflineFile] = []
        for entry in choice.files(for: species) {
            guard let url = api.tileURL(entry) else { continue }
            files.append(OfflineFile(
                name: entry.name, kind: entry.kind, species: entry.kind == "T" ? entry.species : nil, url: url.absoluteString,
                bytes: Int64(entry.bytes ?? 0), done: false, channels: entry.kind == "G" ? entry.channels : nil
            ))
        }
        guard !files.isEmpty else {
            status = "Rien à télécharger pour ce département."
            return
        }
        let department = OfflineDepartment(
            code: choice.code, name: choice.name, species: species.sorted(), files: files, weatherToday: nil,
            weatherFetchedAt: nil, tilesGenerated: manifest.generated, scoringVersion: scoringVersion, error: nil
        )
        do {
            try await store.begin(department)
        } catch {
            fail(Problem("Le téléchargement n'a pas pu commencer : espace disque ou stockage indisponible", error: error, retryable: false))
            return
        }
        progress[choice.code] = Progress(filesTotal: files.count, bytesExpected: department.bytes)
        written[choice.code] = [:]
        for file in files {
            guard let url = URL(string: file.url) else { continue }
            let destination = await store.fileURL(code: choice.code, name: file.name)
            downloads.download(url, to: destination, tag: Self.tag(code: choice.code, name: file.name))
        }
        await refresh()
    }

    static func tag(code: String, name: String) -> String { code + "|" + name }

    private func handle(_ event: DownloadManager.Event) async {
        let parts = event.tag.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let (code, name) = (parts[0], parts[1])
        switch event.outcome {
        case .progress(let writtenBytes, _):
            written[code, default: [:]][name] = writtenBytes
            progress[code]?.bytesWritten = written[code]?.values.reduce(0, +) ?? 0
        case .failed(let message):
            try? await store.markError(code: code, "\(name) : \(message)")
            progress[code] = nil
            fail(Problem("Téléchargement du département \(code) interrompu", detail: "\(name) : \(message)"), retry: .resume(code: code))
            await refresh()
        case .finished(let url):
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int64) ?? 0
            try? await store.markDone(code: code, name: name, bytes: size)
            progress[code]?.filesDone += 1
            if let department = await store.department(code), department.filesDone {
                await fetchWeather(for: department)
            }
            await refresh()
        }
    }

    // MARK: Météo embarquée

    /// Météo des 11 jours sur l'emprise du département (lue dans l'en-tête du premier PMTiles), par
    /// sous-emprises de quelques dizaines de cellules ; le département n'est complet qu'après.
    func fetchWeather(for department: OfflineDepartment) async {
        progress[department.code, default: Progress()].fetchingWeather = true
        defer {
            progress[department.code] = nil
        }
        do {
            guard let first = department.files.first(where: { $0.done }) else { return }
            let fileURL = await store.fileURL(code: department.code, name: first.name)
            let header = try await PMTilesReader(source: try LocalFileSource(url: fileURL)).readHeader()
            let b = header.bounds
            let bbox = BBox(minLon: b.minLon, minLat: b.minLat, maxLon: b.maxLon, maxLat: b.maxLat)
            var responses: [WeatherBBoxResponse] = []
            for part in bbox.split(maxSpan: Self.weatherSpan) {
                responses.append(try await api.weather(bbox: part, species: department.species))
            }
            try await store.saveWeather(code: department.code, responses: responses, fetchedAt: ISO8601DateFormatter().string(from: .now))
            status = nil
            if problemRetry == .resume(code: department.code) {
                fail(nil)
            }
            await refresh()
            await publishLocalFiles()
        } catch {
            try? await store.markError(code: department.code, "météo : \(Problem.technical(error))")
            fail(Problem("Météo du département \(department.code) non récupérée", error: error), retry: .resume(code: department.code))
            await refresh()
        }
    }

    /// Rafraîchit la météo seule (petit), sans toucher aux tuiles.
    func refreshWeather(code: String) async {
        guard let department = await store.department(code), department.filesDone else { return }
        await fetchWeather(for: department)
    }

    func delete(code: String) async {
        do {
            try await store.remove(code: code)
        } catch {
            fail(Problem("Le département \(code) n'a pas pu être supprimé", error: error), retry: .delete(code: code))
        }
        progress[code] = nil
        await refresh()
        await publishLocalFiles()
    }

    /// « Réessayer » sur un département incomplet (étape B4) : relance les fichiers qui manquent,
    /// puis la météo ; un département aux tuiles complètes ne redemande que la météo.
    func resume(code: String) async {
        guard progress[code] == nil, let department = await store.department(code) else { return }
        if department.filesDone {
            await fetchWeather(for: department)
            return
        }
        let missing = department.files.filter { !$0.done }
        progress[code] = Progress(
            filesDone: department.files.count - missing.count, filesTotal: department.files.count,
            bytesExpected: missing.reduce(0) { $0 + $1.bytes }
        )
        written[code] = [:]
        for file in missing {
            guard let url = URL(string: file.url) else { continue }
            let destination = await store.fileURL(code: code, name: file.name)
            downloads.download(url, to: destination, tag: Self.tag(code: code, name: file.name))
        }
        await refresh()
    }

    private func fail(_ problem: Problem?, retry: Retry? = nil) {
        self.problem = problem
        problemRetry = problem == nil ? nil : retry
    }

    /// « Réessayer » sous le message de l'écran Hors ligne.
    func retry() async {
        let retry = problemRetry
        fail(nil)
        switch retry {
        case .start: await start(api: api)
        case .resume(let code): await resume(code: code)
        case .delete(let code): await delete(code: code)
        case nil: break
        }
    }

    /// Météo embarquée de tous les départements complets, pour la carte sans réseau.
    func offlineWeather() async -> [WeatherBBoxResponse] {
        await store.allWeather()
    }
}
