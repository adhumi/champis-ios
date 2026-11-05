import ChampisPMTiles
import ChampisScoring
import Foundation

/// Tuile d'un PMTiles par groupe (`G-<groupe>-…`, spec › Points ouverts › Les clients lisent les
/// PMTiles par groupe, 5 nov. 2026) : un canal par espèce, dans l'ordre de `species` du manifeste.
nonisolated enum GroupTile {
    /// Canal `index` d'une tuile `G` décodée, sous la forme d'une tuile `T` gris + alpha que le
    /// coloriste et la fiche lisent comme aujourd'hui : gris = valeur du canal, alpha 0 là où le
    /// canal vaut `nodata` (pas de forêt pour cette espèce). Si l'échelle du `G` différait de celle
    /// des `T`, la valeur serait ramenée à l'échelle des `T` ; `nil` si la tuile n'a pas ce canal.
    static func channel(
        _ png: DecodedPNG, index: Int, encoding: Palette.GroupTileEncoding, tileEncoding: Palette.TileEncoding
    ) -> DecodedPNG? {
        let channels = encoding.channels.count
        let n = png.width * png.height
        guard png.channels == channels, index >= 0, index < channels, png.data.count >= n * channels else { return nil }
        let nodata = UInt8(clamping: encoding.nodata)
        let rescale = encoding.scale != tileEncoding.scale
        var out = [UInt8](repeating: 0, count: n * 2)
        png.data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for i in 0..<n {
                    let v = src[i * channels + index]
                    if v == nodata {
                        dst[i * 2] = UInt8(clamping: tileEncoding.nodata)
                        dst[i * 2 + 1] = 0
                    } else {
                        dst[i * 2] = rescale ? UInt8(clamping: Int((Double(v) / encoding.scale * tileEncoding.scale).rounded())) : v
                        dst[i * 2 + 1] = 255
                    }
                }
            }
        }
        return DecodedPNG(width: png.width, height: png.height, channels: 2, data: out)
    }
}

/// Lecture et décodage des PMTiles hors du MainActor : un lecteur par fichier du manifeste
/// (`T-<espèce>…` par espèce, `G-<groupe>…` par groupe, `A-300m…` pour les classes d'altitude),
/// cache mémoire des tuiles décodées et cache disque des octets lus (`DiskTileCache`, skill
/// `offline`). Source distante par requêtes Range ou fichier local embarqué : le lecteur ne fait pas
/// la différence (`TileSource`).
///
/// Dès qu'un `G` du jeu complet est dans le manifeste, `T` de chaque espèce du groupe se lit dans
/// ses canaux : une seule requête Range et un seul décodage par tuile, partagés entre les espèces
/// (cache mémoire et lectures en cours par fichier), puis extraction du canal. Sans `G`, repli sur
/// les `T` : l'app marche dans les deux cas et bascule sans mise à jour quand les `G` paraissent.
actor TileStore {
    private struct Key: Hashable {
        let name: String
        let z: Int
        let x: Int
        let y: Int
    }

    /// Un fichier `G` : ses espèces dans l'ordre des canaux.
    nonisolated struct GroupFile: Sendable {
        let name: String
        let reader: PMTilesReader
        let species: [String]
    }

    private var terrainReaders: [String: PMTilesReader] = [:]
    private var terrainNames: [String: String] = [:]
    /// Espèce → fichier `G` du jeu complet qui porte son canal (plusieurs espèces partagent le même).
    private var groupBySpecies: [String: GroupFile] = [:]
    private var altReader: PMTilesReader?
    private var altName = ""
    /// Encodage des `G` (`palette.json › group_tile_encoding`) ; absent sur une vieille API : les `G`
    /// sont alors ignorés et les `T` lus, jamais un ordre de canaux deviné.
    private var groupEncoding: Palette.GroupTileEncoding?
    private var tileEncoding: Palette.TileEncoding?
    /// Fichiers des départements embarqués (skill `offline`), lus avant la source distante : les `G`
    /// d'abord, puis les `T` (un département téléchargé en `T` reste lisible).
    private var localGroups: [String: [GroupFile]] = [:]
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
    var species: Set<String> { Set(terrainReaders.keys).union(groupBySpecies.keys) }
    /// Espèces lues dans un `G` plutôt que dans leur `T` (réglages, tests).
    var groupedSpecies: Set<String> { Set(groupBySpecies.keys) }

    /// Entrées du manifeste à lire en ligne : pour chaque espèce un fichier `T`, par groupe le fichier
    /// `G` (et son éventuelle seconde partie), et le fichier `A`.
    ///
    /// Le manifeste liste aussi, depuis le 1er nov. 2026, un jeu par département (champ `dept`)
    /// pour le hors ligne : ces fichiers ne contiennent que les tuiles de leur département, la
    /// carte en ligne doit lire le jeu complet (sans `dept`). Préférence, dans l'ordre : jeu complet
    /// plutôt que jeu d'un département, version de scoring de l'app plutôt qu'une autre, puis le
    /// dernier nom par ordre alphabétique. Fonction pure, testée sans réseau : le 4 nov. 2026, « le
    /// dernier par nom » tout court choisissait le département 70 et la carte restait vide ailleurs.
    ///
    /// Un `G` n'est retenu que s'il va avec les `T` choisis de ses espèces (même `depts_hash`, même
    /// version de scoring) : un `G` d'un autre jeu laisserait des trous, les `T` restent la référence.
    nonisolated static func chooseEntries(
        _ tiles: [TilesManifest.Entry], scoringVersion: String
    ) -> (terrain: [String: TilesManifest.Entry], groups: [TilesManifest.Entry], alt: TilesManifest.Entry?) {
        func rank(_ e: TilesManifest.Entry) -> (Int, Int, String) {
            (e.dept == nil ? 1 : 0, e.scoringVersion == scoringVersion ? 1 : 0, e.name)
        }
        func better(_ a: TilesManifest.Entry, than b: TilesManifest.Entry?) -> Bool {
            guard let b else { return true }
            return rank(a) > rank(b)
        }
        var terrain: [String: TilesManifest.Entry] = [:]
        var groups: [String: TilesManifest.Entry] = [:]  // clé : groupe et partie
        var alt: TilesManifest.Entry?
        for entry in tiles {
            switch entry.kind {
            case "T":
                guard let sid = entry.species else { continue }
                if better(entry, than: terrain[sid]) {
                    terrain[sid] = entry
                }
            case "G":
                guard let group = entry.group, let channels = entry.channels, !channels.isEmpty else { continue }
                let key = group + "#" + String(entry.part ?? 1)
                if better(entry, than: groups[key]) {
                    groups[key] = entry
                }
            case "A":
                if better(entry, than: alt) {
                    alt = entry
                }
            default:
                continue
            }
        }
        let kept = groups.values
            .filter { g in
                (g.channels ?? []).allSatisfy { sid in
                    guard let t = terrain[sid] else { return true }
                    return t.deptsHash == g.deptsHash && t.scoringVersion == g.scoringVersion
                }
            }
            .sorted { $0.name < $1.name }
        return (terrain, kept, alt)
    }

    /// (Re)configure les lecteurs d'après le manifeste (voir `chooseEntries`). `palette` donne
    /// l'encodage des `G` ; sans `group_tile_encoding` (vieille API), seuls les `T` sont lus.
    func configure(manifest: TilesManifest, api: ChampisAPI, scoringVersion: String, palette: Palette) {
        terrainReaders = [:]
        terrainNames = [:]
        groupBySpecies = [:]
        altReader = nil
        altName = ""
        groupEncoding = palette.groupTileEncoding
        tileEncoding = palette.tileEncoding
        cache = [:]
        order = []
        let chosen = Self.chooseEntries(manifest.tiles, scoringVersion: scoringVersion)
        if let entry = chosen.alt, let url = api.tileURL(entry) {
            altReader = PMTilesReader(source: RemoteRangeSource(url: url, session: session))
            altName = entry.name
        }
        for (sid, entry) in chosen.terrain {
            guard let url = api.tileURL(entry) else { continue }
            terrainReaders[sid] = PMTilesReader(source: RemoteRangeSource(url: url, session: session))
            terrainNames[sid] = entry.name
        }
        if let encoding = groupEncoding {
            for entry in chosen.groups {
                guard let channels = entry.channels, channels.count <= encoding.channels.count,
                      let url = api.tileURL(entry)
                else { continue }
                let file = GroupFile(name: entry.name, reader: PMTilesReader(source: RemoteRangeSource(url: url, session: session)), species: channels)
                for sid in channels where groupBySpecies[sid] == nil {
                    groupBySpecies[sid] = file
                }
            }
        }
        // Changement de hash dans le manifeste = nouveau dossier ; les anciens sont purgés.
        var keep = Set(terrainNames.values).union(groupBySpecies.values.map(\.name))
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

    /// Lecteurs fournis directement (tests) ; `palette` requise pour lire des `groups`.
    func install(terrain: [String: PMTilesReader], groups: [GroupFile] = [], alt: PMTilesReader?, palette: Palette? = nil) {
        terrainReaders = terrain
        terrainNames = Dictionary(uniqueKeysWithValues: terrain.keys.map { ($0, "T-" + $0) })
        groupBySpecies = [:]
        groupEncoding = palette?.groupTileEncoding
        tileEncoding = palette?.tileEncoding
        for file in groups {
            for sid in file.species where groupBySpecies[sid] == nil {
                groupBySpecies[sid] = file
            }
        }
        altReader = alt
        altName = alt == nil ? "" : "A"
        cache = [:]
        order = []
    }

    /// Remplace la liste des fichiers embarqués ; chacun est lu par `LocalFileSource`.
    func setLocalFiles(_ files: [OfflineLocalFile]) {
        localGroups = [:]
        localTerrain = [:]
        localAlt = []
        for file in files {
            guard let reader = (try? LocalFileSource(url: file.url)).map({ PMTilesReader(source: $0) }) else { continue }
            let name = "local:" + file.url.lastPathComponent
            if file.kind == "T", let species = file.species {
                localTerrain[species, default: []].append((name: name, reader: reader))
            } else if file.kind == "G", let channels = file.channels, !channels.isEmpty {
                let group = GroupFile(name: name, reader: reader, species: channels)
                for sid in channels {
                    localGroups[sid, default: []].append(group)
                }
            } else if file.kind == "A" {
                localAlt.append((name: name, reader: reader))
            }
        }
        cache = [:]
        order = []
    }

    var hasLocalFiles: Bool { !localGroups.isEmpty || !localTerrain.isEmpty || !localAlt.isEmpty }

    /// Tuile `T` d'une espèce, décodée ; `nil` si l'espèce n'a pas de fichier ou la tuile n'existe pas.
    /// Les fichiers embarqués passent d'abord (`G` puis `T`) ; sans réseau, une tuile hors d'eux est
    /// `nil`. En ligne, le canal du `G` quand il existe, sinon le `T`.
    func terrainTile(species: String, z: Int, x: Int, y: Int) async throws -> DecodedPNG? {
        let localG = localGroups[species] ?? []
        let localT = localTerrain[species] ?? []
        for file in localG {
            if let png = try await groupTile(file, species: species, z: z, x: x, y: y, useDisk: false) {
                return png
            }
        }
        for file in localT {
            if let png = try await tile(reader: file.reader, key: Key(name: file.name, z: z, x: x, y: y), useDisk: false) {
                return png
            }
        }
        do {
            if let group = groupBySpecies[species] {
                // Un G porte tout son groupe : une tuile qu'il n'a pas, aucun T ne l'a. Pas de second appel.
                return try await groupTile(group, species: species, z: z, x: x, y: y, useDisk: true)
            }
            guard let reader = terrainReaders[species], let name = terrainNames[species] else { return nil }
            return try await tile(reader: reader, key: Key(name: name, z: z, x: x, y: y), useDisk: true)
        } catch where !localG.isEmpty || !localT.isEmpty {
            return nil  // hors ligne, hors des départements embarqués
        }
    }

    /// Canal d'une espèce dans une tuile `G` : la tuile RGBA est lue et décodée une fois pour le
    /// fichier (cache et lectures en cours par `Key`), chaque espèce en extrait son canal.
    private func groupTile(_ file: GroupFile, species: String, z: Int, x: Int, y: Int, useDisk: Bool) async throws -> DecodedPNG? {
        guard let encoding = groupEncoding, let tileEncoding, let index = file.species.firstIndex(of: species) else { return nil }
        guard let png = try await tile(reader: file.reader, key: Key(name: file.name, z: z, x: x, y: y), useDisk: useDisk) else {
            return nil
        }
        return GroupTile.channel(png, index: index, encoding: encoding, tileEncoding: tileEncoding)
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
