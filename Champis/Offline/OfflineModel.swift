import ChampisPMTiles
import Foundation
import Observation

/// Un département proposé au téléchargement, d'après le manifeste `GET /tiles` (entrées `dept`).
nonisolated struct DownloadableDepartment: Identifiable, Hashable, Sendable {
    let code: String
    let name: String?
    /// Espèce → entrée `T` du manifeste.
    let terrain: [String: TilesManifest.Entry]
    let altitude: TilesManifest.Entry?

    var id: String { code }
    var title: String { name.map { "\($0) (\(code))" } ?? "Département \(code)" }

    func bytes(for species: [String]) -> Int64 {
        let t = species.compactMap { terrain[$0]?.bytes }.reduce(0, +)
        return Int64(t + (altitude?.bytes ?? 0))
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

    /// Côté maximal d'une sous-emprise météo, en degrés (≈ 6 × 4 cellules de 5 km, sous la limite de 40).
    static let weatherSpan = 0.3

    private(set) var departments: [OfflineDepartment] = []
    private(set) var progress: [String: Progress] = [:]
    private(set) var status: String?
    private(set) var totalBytes: Int64 = 0

    @ObservationIgnored let store: OfflineStore
    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private(set) var api: ChampisAPI
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var written: [String: [String: Int64]] = [:]
    /// Appelé quand la liste des fichiers lisibles hors ligne change (le lecteur de tuiles s'y branche).
    @ObservationIgnored var onLocalFilesChanged: (@MainActor ([OfflineLocalFile]) async -> Void)?

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
            status = "Hors ligne : manifeste illisible (\(error.localizedDescription))"
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
    static func downloadable(from manifest: TilesManifest, names: [String: String]) -> [DownloadableDepartment] {
        var byCode: [String: (terrain: [String: TilesManifest.Entry], altitude: TilesManifest.Entry?)] = [:]
        for entry in manifest.tiles {
            guard let dept = entry.dept else { continue }
            var current = byCode[dept] ?? ([:], nil)
            if entry.kind == "T", let species = entry.species {
                current.terrain[species] = entry
            } else if entry.kind == "A" {
                current.altitude = entry
            }
            byCode[dept] = current
        }
        return byCode
            .map { DownloadableDepartment(code: $0.key, name: names[$0.key], terrain: $0.value.terrain, altitude: $0.value.altitude) }
            .sorted { $0.code < $1.code }
    }

    // MARK: Téléchargement

    /// Lance le téléchargement d'un département pour les espèces choisies ; rien n'est marqué
    /// disponible tant que tuiles, couche A et météo ne sont pas tous écrits.
    func download(_ choice: DownloadableDepartment, species: [String], manifest: TilesManifest, scoringVersion: String) async {
        var files: [OfflineFile] = []
        for sid in species.sorted() {
            guard let entry = choice.terrain[sid], let url = api.tileURL(entry) else { continue }
            files.append(OfflineFile(name: entry.name, kind: "T", species: sid, url: url.absoluteString, bytes: Int64(entry.bytes ?? 0), done: false))
        }
        if let alt = choice.altitude, let url = api.tileURL(alt) {
            files.append(OfflineFile(name: alt.name, kind: "A", species: nil, url: url.absoluteString, bytes: Int64(alt.bytes ?? 0), done: false))
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
            status = "Téléchargement impossible : \(error.localizedDescription)"
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
            status = "Téléchargement de \(code) interrompu : \(message)"
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
    /// sous-emprises sous la limite de 40 cellules ; le département n'est complet qu'après.
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
            await refresh()
            await publishLocalFiles()
        } catch {
            try? await store.markError(code: department.code, "météo : \(error.localizedDescription)")
            status = "Météo de \(department.code) non récupérée : \(error.localizedDescription)"
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
            status = "Suppression impossible : \(error.localizedDescription)"
        }
        progress[code] = nil
        await refresh()
        await publishLocalFiles()
    }

    /// Météo embarquée de tous les départements complets, pour la carte sans réseau.
    func offlineWeather() async -> [WeatherBBoxResponse] {
        await store.allWeather()
    }
}
