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
    /// Tuiles décodées, absentes comprises (`nil`) : une tuile hors emprise ne se redemande pas.
    private var cache: [Key: DecodedPNG?] = [:]
    private var order: [Key] = []
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

    /// Tuile `T` d'une espèce, décodée ; `nil` si l'espèce n'a pas de fichier ou la tuile n'existe pas.
    func terrainTile(species: String, z: Int, x: Int, y: Int) async throws -> DecodedPNG? {
        guard let reader = terrainReaders[species], let name = terrainNames[species] else { return nil }
        return try await tile(reader: reader, key: Key(name: name, z: z, x: x, y: y))
    }

    /// Tuile de la couche A, décodée ; `nil` sans couche ou hors emprise.
    func altitudeTile(z: Int, x: Int, y: Int) async throws -> DecodedPNG? {
        guard let reader = altReader else { return nil }
        return try await tile(reader: reader, key: Key(name: altName, z: z, x: x, y: y))
    }

    private func tile(reader: PMTilesReader, key: Key) async throws -> DecodedPNG? {
        if let hit = cache[key] { return hit }
        var data: Data?
        var fromDisk = false
        switch disk?.read(file: key.name, z: key.z, x: key.x, y: key.y) ?? .miss {
        case .tile(let cached):
            data = cached
            fromDisk = true
        case .absent:
            fromDisk = true
        case .miss:
            data = try await reader.tile(z: key.z, x: key.x, y: key.y)
        }
        if !fromDisk {
            try? disk?.write(file: key.name, z: key.z, x: key.x, y: key.y, data: data)
        }
        let png = try data.map { try PNGDecoder.decode($0) }
        remember(key, png)
        return png
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
