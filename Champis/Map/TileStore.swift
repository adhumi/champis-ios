import ChampisPMTiles
import ChampisScoring
import Foundation
import Synchronization

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

/// Le fichier distant a changé pendant la session (jeu republié sous le même nom) : la lecture en
/// cours échoue, `TileStore` oublie ce qu'il avait lu de l'ancienne version.
nonisolated struct TileFileChanged: Error, Equatable {}

/// Version d'un fichier PMTiles distant vue par cette session (taille totale et ETag des réponses
/// Range) : une réponse d'une autre version que celle déjà lue (ou que celle du cache disque) est
/// refusée, pour ne jamais mélanger deux versions d'un fichier.
nonisolated final class RemoteFileVersion: Sendable {
    private nonisolated struct State {
        var known: DiskTileCache.Stamp?
        var changed = false
        /// Changements de version vus pendant la session.
        var flips = 0
    }

    /// Au-delà de ce nombre de changements dans une session, l'ETag n'est plus comparé, seule la
    /// taille l'est : un serveur dont l'ETag varierait d'une réponse à l'autre pour le même
    /// fichier ne doit pas faire relire la carte sans fin.
    static let maxFlips = 3

    private let state: Mutex<State>

    /// `known` : ce qu'on sait avant la première réponse (tampon du cache disque, sinon `bytes`
    /// du manifeste).
    init(known: DiskTileCache.Stamp?) {
        state = Mutex(State(known: known))
    }

    /// Version connue, pour tamponner le cache disque.
    var stamp: DiskTileCache.Stamp? {
        state.withLock { $0.known }
    }

    /// Appelé à chaque réponse Range (`RemoteRangeSource.onResponse`).
    func observe(etag: String?, total: Int64?) throws {
        let same = state.withLock { state -> Bool in
            // un validateur faible (`W/"…"`) désigne le même contenu que le fort
            let tag = etag.map { $0.hasPrefix("W/") ? String($0.dropFirst(2)) : $0 }
            let seen = DiskTileCache.Stamp(bytes: total, etag: state.flips < RemoteFileVersion.maxFlips ? tag : nil)
            guard let known = state.known else {
                state.known = seen
                return true
            }
            guard known.matches(seen) else {
                state.changed = true
                state.flips += 1
                return false
            }
            state.known = known.merged(with: seen)
            return true
        }
        if !same { throw TileFileChanged() }
    }

    /// Vrai une seule fois après un changement ; la version connue est oubliée, la prochaine
    /// réponse fait foi.
    func takeChanged() -> Bool {
        state.withLock { state in
            guard state.changed else { return false }
            state.changed = false
            state.known = nil
            return true
        }
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
    /// Couche E (altitude par pas de 20 m, 13 nov. 2026), préférée à la couche A quand la palette
    /// porte son encodage : voir `altitudeTile(z:x:y:palette:)`.
    private var elevReader: PMTilesReader?
    private var elevName = ""
    /// Encodage des `G` (`palette.json › group_tile_encoding`) ; absent sur une vieille API : les `G`
    /// sont alors ignorés et les `T` lus, jamais un ordre de canaux deviné.
    private var groupEncoding: Palette.GroupTileEncoding?
    private var tileEncoding: Palette.TileEncoding?
    /// Fichiers des départements embarqués (skill `offline`), lus avant la source distante : les `G`
    /// d'abord, puis les `T` (un département téléchargé en `T` reste lisible).
    private var localGroups: [String: [GroupFile]] = [:]
    private var localTerrain: [String: [(name: String, reader: PMTilesReader)]] = [:]
    private var localAlt: [(name: String, reader: PMTilesReader)] = []
    private var localElev: [(name: String, reader: PMTilesReader)] = []
    /// Tuiles décodées, absentes comprises (`nil`) : une tuile hors emprise ne se redemande pas.
    private var cache: [Key: DecodedPNG?] = [:]
    private var order: [Key] = []
    /// Lectures en cours : une tuile demandée deux fois en même temps (plusieurs rendus, fiche au
    /// toucher) ne part qu'une fois sur le réseau.
    private var inflight: [Key: Task<DecodedPNG?, any Error>] = [:]
    /// Version vue de chaque fichier distant, par nom (cache disque périmé, 13 nov. 2026).
    private var versions: [String: RemoteFileVersion] = [:]
    /// Incrémenté quand un fichier distant change : une lecture commencée avant n'est pas gardée.
    private var generations: [String: Int] = [:]
    private let capacity: Int
    private let session: URLSession
    private let disk: DiskTileCache?

    init(capacity: Int = 512, session: URLSession = .shared, disk: DiskTileCache? = nil) {
        self.capacity = capacity
        self.session = session
        self.disk = disk
    }

    var hasAltitudeLayer: Bool { altReader != nil || elevReader != nil }
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
    ) -> (terrain: [String: TilesManifest.Entry], groups: [TilesManifest.Entry], alt: TilesManifest.Entry?, elev: TilesManifest.Entry?) {
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
        var elev: TilesManifest.Entry?
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
            case "E":
                if better(entry, than: elev) {
                    elev = entry
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
        return (terrain, kept, alt, elev)
    }

    /// (Re)configure les lecteurs d'après le manifeste (voir `chooseEntries`). `palette` donne
    /// l'encodage des `G` ; sans `group_tile_encoding` (vieille API), seuls les `T` sont lus.
    func configure(manifest: TilesManifest, api: ChampisAPI, scoringVersion: String, palette: Palette) {
        terrainReaders = [:]
        terrainNames = [:]
        groupBySpecies = [:]
        altReader = nil
        altName = ""
        elevReader = nil
        elevName = ""
        groupEncoding = palette.groupTileEncoding
        tileEncoding = palette.tileEncoding
        cache = [:]
        order = []
        versions = [:]
        let chosen = Self.chooseEntries(manifest.tiles, scoringVersion: scoringVersion)
        if let entry = chosen.alt, let url = api.tileURL(entry) {
            altReader = remoteReader(entry, url: url)
            altName = entry.name
        }
        if let entry = chosen.elev, let url = api.tileURL(entry) {
            elevReader = remoteReader(entry, url: url)
            elevName = entry.name
        }
        for (sid, entry) in chosen.terrain {
            guard let url = api.tileURL(entry) else { continue }
            terrainReaders[sid] = remoteReader(entry, url: url)
            terrainNames[sid] = entry.name
        }
        if let encoding = groupEncoding {
            for entry in chosen.groups {
                guard let channels = entry.channels, channels.count <= encoding.channels.count,
                      let url = api.tileURL(entry)
                else { continue }
                let file = GroupFile(name: entry.name, reader: remoteReader(entry, url: url), species: channels)
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
        if !elevName.isEmpty {
            keep.insert(elevName)
        }
        _ = try? disk?.prune(keeping: keep)
    }

    /// Lecteur d'un fichier distant du manifeste. Son dossier du cache disque n'est gardé que s'il
    /// vient de la version que le manifeste annonce (`bytes`) ; ensuite chaque réponse Range est
    /// comparée à la version connue (taille totale, ETag), et une autre version fait échouer la
    /// lecture (`TileFileChanged`), reprise dans `tile(reader:key:useDisk:)`.
    private func remoteReader(_ entry: TilesManifest.Entry, url: URL) -> PMTilesReader {
        let expected = DiskTileCache.Stamp(bytes: entry.bytes.map { Int64($0) }, etag: nil)
        let kept = disk?.validate(file: entry.name, against: expected)
        let version = RemoteFileVersion(known: kept?.merged(with: expected) ?? expected)
        versions[entry.name] = version
        let source = RemoteRangeSource(url: url, session: session, onResponse: { etag, total in
            try version.observe(etag: etag, total: total)
        })
        return PMTilesReader(source: source)
    }

    /// Le fichier `name` a changé à la source : ce qui en a été lu (mémoire, disque, répertoires
    /// du lecteur) est oublié, la prochaine lecture repart de son en-tête.
    private func forget(name: String, reader: PMTilesReader) {
        generations[name, default: 0] += 1
        reader.reset()
        try? disk?.remove(file: name)
        let stale = Set(order.filter { $0.name == name })
        for key in stale {
            cache[key] = nil
        }
        order.removeAll { stale.contains($0) }
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
        // Sans encodage des G (vieille palette), les G sont ignorés et les T lus, comme `configure`.
        if groupEncoding != nil {
            for file in groups {
                for sid in file.species where groupBySpecies[sid] == nil {
                    groupBySpecies[sid] = file
                }
            }
        }
        altReader = alt
        altName = alt == nil ? "" : "A"
        elevReader = nil
        elevName = ""
        cache = [:]
        order = []
        versions = [:]
    }

    /// Remplace la liste des fichiers embarqués ; chacun est lu par `LocalFileSource`.
    func setLocalFiles(_ files: [OfflineLocalFile]) {
        localGroups = [:]
        localTerrain = [:]
        localAlt = []
        localElev = []
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
            } else if file.kind == "E" {
                localElev.append((name: name, reader: reader))
            }
        }
        cache = [:]
        order = []
    }

    var hasLocalFiles: Bool { !localGroups.isEmpty || !localTerrain.isEmpty || !localAlt.isEmpty || !localElev.isEmpty }

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

    /// Tuile d'altitude telle que le coloriste l'attend pour cette palette. Sans encodage de la
    /// couche E (API ancienne) : la tuile A, indices de classe. Avec : indices de tranche de 20 m,
    /// lus dans la couche E (embarquée, puis en ligne) ou, si elle manque pour cette tuile, dans la
    /// couche A convertie (`fineIndices`) : le pixel prend alors l'altitude du centre de sa classe,
    /// et le score est celui d'avant la couche E.
    func altitudeTile(z: Int, x: Int, y: Int, palette: Palette) async throws -> DecodedPNG? {
        guard let elev = palette.elevEncoding else {
            return try await altitudeTile(z: z, x: x, y: y)
        }
        for file in localElev {
            if let png = try await tile(reader: file.reader, key: Key(name: file.name, z: z, x: x, y: y), useDisk: false) {
                return png
            }
        }
        if let reader = elevReader {
            // une couche E injoignable ne prive pas de la couche A (embarquée ou en cache)
            if let png = try? await tile(reader: reader, key: Key(name: elevName, z: z, x: x, y: y), useDisk: true) {
                return png
            }
        }
        guard let classes = try await altitudeTile(z: z, x: x, y: y) else { return nil }
        return Self.fineIndices(fromClasses: classes, alt: palette.altEncoding, elev: elev)
    }

    /// Tuile A (indice de classe de `alt.classM` mètres) réécrite en indices de tranche de la
    /// couche E : chaque pixel prend la tranche qui contient le centre de sa classe (classe 450 m,
    /// pas de 20 m → tranche 22, dont le milieu est 450 m). Inconnu (alpha 0 ou nodata) → nodata.
    nonisolated static func fineIndices(
        fromClasses png: DecodedPNG, alt: Palette.AltEncoding, elev: Palette.ElevEncoding
    ) -> DecodedPNG {
        let c = png.channels
        guard c >= 1, elev.stepM > 0 else { return png }
        let count = png.data.count / c
        let hasAlpha = c == 2 || c == 4
        let limit = min(elev.nodata - 1, 254)
        var data = [UInt8](repeating: 0, count: count * 2)
        for i in 0..<count {
            let k = Int(png.data[i * c])
            if (hasAlpha && png.data[i * c + c - 1] == 0) || k == alt.nodata {
                data[i * 2] = UInt8(clamping: elev.nodata)
                data[i * 2 + 1] = 0
            } else {
                let index = Int(((Double(k) + 0.5) * alt.classM / elev.stepM).rounded(.down))
                data[i * 2] = UInt8(clamping: min(index, limit))
                data[i * 2 + 1] = 255
            }
        }
        return DecodedPNG(width: png.width, height: png.height, channels: 2, data: data)
    }

    private func tile(reader: PMTilesReader, key: Key, useDisk: Bool) async throws -> DecodedPNG? {
        if let hit = cache[key] { return hit }
        if let running = inflight[key] { return try await running.value }
        // Lecture disque, réseau et décodage hors de l'acteur : les tuiles voisines se chargent en
        // parallèle au lieu d'attendre chacune leur tour.
        let disk = useDisk ? disk : nil
        let (name, z, x, y) = (key.name, key.z, key.x, key.y)
        let version = useDisk ? versions[name] : nil
        let generation = generations[name, default: 0]
        let task = Task.detached(priority: .userInitiated) {
            try await Self.fetch(reader: reader, disk: disk, version: version, name: name, z: z, x: x, y: y)
        }
        inflight[key] = task
        do {
            let png = try await task.value
            inflight[key] = nil
            // le fichier a changé entre-temps : cette tuile vient peut-être de l'ancienne version
            if generations[name, default: 0] == generation {
                remember(key, png)
            }
            return png
        } catch {
            inflight[key] = nil
            if version?.takeChanged() == true {
                forget(name: name, reader: reader)
            }
            throw error
        }
    }

    private nonisolated static func fetch(
        reader: PMTilesReader, disk: DiskTileCache?, version: RemoteFileVersion?, name: String, z: Int, x: Int, y: Int
    ) async throws -> DecodedPNG? {
        let data: Data?
        switch disk?.read(file: name, z: z, x: x, y: y) ?? .miss {
        case .tile(let cached):
            data = cached
        case .absent:
            data = nil
        case .miss:
            data = try await reader.tile(z: z, x: x, y: y)
            // tamponnée par la version que le serveur vient d'annoncer : un dossier d'une autre
            // version est effacé avant d'écrire
            try? disk?.write(file: name, z: z, x: x, y: y, data: data, stamp: version?.stamp)
        }
        // une tuile fait 256 × 256 : toute autre dimension est refusée dès l'en-tête du PNG
        return try data.map { try PNGDecoder.decode($0, side: TileMath.tileSize) }
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
