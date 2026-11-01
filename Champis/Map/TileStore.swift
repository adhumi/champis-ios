import ChampisPMTiles
import Foundation

/// Lecture et décodage des PMTiles hors du MainActor : un lecteur par fichier du manifeste
/// (`T-<espèce>…` par espèce, `A-300m…` pour les classes d'altitude), cache mémoire des tuiles
/// décodées et cache disque des octets lus (`DiskTileCache`, skill `offline`). Source distante par
/// requêtes Range aujourd'hui, fichier local demain : le lecteur ne fait pas la différence
/// (`TileSource`).
actor TileStore {
    private struct Key: Hashable {
        let name: String
        let z: Int
        let x: Int
        let y: Int
    }

    private var terrainReaders: [String: PMTilesReader] = [:]
    private var terrainNames: [String: String] = [:]
    private var altReader: PMTilesReader?
    private var altName = ""
    /// Fichiers des départements embarqués (skill `offline`), lus avant la source distante.
    private var localTerrain: [String: [(name: String, reader: PMTilesReader)]] = [:]
    private var localAlt: [(name: String, reader: PMTilesReader)] = []
    /// Tuiles décodées, absentes comprises (`nil`) : une tuile hors emprise ne se redemande pas.
    private var cache: [Key: DecodedPNG?] = [:]
    private var order: [Key] = []
    /// Lectures en cours : une tuile demandée deux fois en même temps (plusieurs rendus, fiche au
    /// toucher) ne part qu'une fois sur le réseau.
    private var inflight: [Key: Task<DecodedPNG?, any Error>] = [:]
    private let capacity: Int
    private let session: URLSession
    private let disk: DiskTileCache?

    init(capacity: Int = 512, session: URLSession = .shared, disk: DiskTileCache? = nil) {
        self.capacity = capacity
        self.session = session
        self.disk = disk
    }

    var hasAltitudeLayer: Bool { altReader != nil }
    var species: Set<String> { Set(terrainReaders.keys) }

    /// (Re)configure les lecteurs d'après le manifeste. Pour une espèce, l'entrée dont la version de
    /// scoring est celle de l'app est préférée ; à défaut la dernière par nom.
    func configure(manifest: TilesManifest, api: ChampisAPI, scoringVersion: String) {
        terrainReaders = [:]
        terrainNames = [:]
        altReader = nil
        altName = ""
        cache = [:]
        order = []
        var chosen: [String: TilesManifest.Entry] = [:]
        for entry in manifest.tiles.sorted(by: { $0.name < $1.name }) {
            switch entry.kind {
            case "T":
                guard let sid = entry.species else { continue }
                if let current = chosen[sid], current.scoringVersion == scoringVersion,
                   entry.scoringVersion != scoringVersion {
                    continue
                }
                chosen[sid] = entry
            case "A":
                if let url = api.tileURL(entry) {
                    altReader = PMTilesReader(source: RemoteRangeSource(url: url, session: session))
                    altName = entry.name
                }
            default:
                continue
            }
        }
        for (sid, entry) in chosen {
            guard let url = api.tileURL(entry) else { continue }
            terrainReaders[sid] = PMTilesReader(source: RemoteRangeSource(url: url, session: session))
            terrainNames[sid] = entry.name
        }
        // Changement de hash dans le manifeste = nouveau dossier ; les anciens sont purgés.
        var keep = Set(terrainNames.values)
        if !altName.isEmpty {
            keep.insert(altName)
        }
        _ = try? disk?.prune(keeping: keep)
    }

    /// Octets du cache disque, pour les réglages.
    func diskSize() -> Int64 {
        disk?.totalSize() ?? 0
    }

    func clearDisk() throws {
        try disk?.removeAll()
        cache = [:]
        order = []
    }

    /// Lecteurs fournis directement (tests, et demain les fichiers hors ligne).
    func install(terrain: [String: PMTilesReader], alt: PMTilesReader?) {
        terrainReaders = terrain
        terrainNames = Dictionary(uniqueKeysWithValues: terrain.keys.map { ($0, "T-" + $0) })
        altReader = alt
        altName = alt == nil ? "" : "A"
        cache = [:]
        order = []
    }

    /// Remplace la liste des fichiers embarqués ; chacun est lu par `LocalFileSource`.
    func setLocalFiles(_ files: [OfflineLocalFile]) {
        localTerrain = [:]
        localAlt = []
        for file in files {
            guard let reader = (try? LocalFileSource(url: file.url)).map({ PMTilesReader(source: $0) }) else { continue }
            let entry = (name: "local:" + file.url.lastPathComponent, reader: reader)
            if file.kind == "T", let species = file.species {
                localTerrain[species, default: []].append(entry)
            } else if file.kind == "A" {
                localAlt.append(entry)
            }
        }
        cache = [:]
        order = []
    }

    var hasLocalFiles: Bool { !localTerrain.isEmpty || !localAlt.isEmpty }

    /// Tuile `T` d'une espèce, décodée ; `nil` si l'espèce n'a pas de fichier ou la tuile n'existe pas.
    /// Les fichiers embarqués passent d'abord ; sans réseau, une tuile hors d'eux est `nil`.
    func terrainTile(species: String, z: Int, x: Int, y: Int) async throws -> DecodedPNG? {
        let local = localTerrain[species] ?? []
        for file in local {
            if let png = try await tile(reader: file.reader, key: Key(name: file.name, z: z, x: x, y: y), useDisk: false) {
                return png
            }
        }
        guard let reader = terrainReaders[species], let name = terrainNames[species] else { return nil }
        do {
            return try await tile(reader: reader, key: Key(name: name, z: z, x: x, y: y), useDisk: true)
        } catch where !local.isEmpty {
            return nil  // hors ligne, hors des départements embarqués
        }
    }

    /// Tuile de la couche A, décodée ; `nil` sans couche ou hors emprise.
    func altitudeTile(z: Int, x: Int, y: Int) async throws -> DecodedPNG? {
        for file in localAlt {
            if let png = try await tile(reader: file.reader, key: Key(name: file.name, z: z, x: x, y: y), useDisk: false) {
                return png
            }
        }
        guard let reader = altReader else { return nil }
        do {
            return try await tile(reader: reader, key: Key(name: altName, z: z, x: x, y: y), useDisk: true)
        } catch where !localAlt.isEmpty {
            return nil
        }
    }

    private func tile(reader: PMTilesReader, key: Key, useDisk: Bool) async throws -> DecodedPNG? {
        if let hit = cache[key] { return hit }
        if let running = inflight[key] { return try await running.value }
        // Lecture disque, réseau et décodage hors de l'acteur : les tuiles voisines se chargent en
        // parallèle au lieu d'attendre chacune leur tour.
        let disk = useDisk ? disk : nil
        let (name, z, x, y) = (key.name, key.z, key.x, key.y)
        let task = Task.detached(priority: .userInitiated) {
            try await Self.fetch(reader: reader, disk: disk, name: name, z: z, x: x, y: y)
        }
        inflight[key] = task
        do {
            let png = try await task.value
            inflight[key] = nil
            remember(key, png)
            return png
        } catch {
            inflight[key] = nil
            throw error
        }
    }

    private nonisolated static func fetch(
        reader: PMTilesReader, disk: DiskTileCache?, name: String, z: Int, x: Int, y: Int
    ) async throws -> DecodedPNG? {
        let data: Data?
        switch disk?.read(file: name, z: z, x: x, y: y) ?? .miss {
        case .tile(let cached):
            data = cached
        case .absent:
            data = nil
        case .miss:
            data = try await reader.tile(z: z, x: x, y: y)
            try? disk?.write(file: name, z: z, x: x, y: y, data: data)
        }
        return try data.map { try PNGDecoder.decode($0) }
    }

    private func remember(_ key: Key, _ png: DecodedPNG?) {
        if cache[key] == nil {
            order.append(key)
        }
        cache[key] = .some(png)
        while order.count > capacity {
            let old = order.removeFirst()
            cache[old] = nil
        }
    }
}
