import Foundation

/// Stockage local des observations et des coins (décision du 31 oct. 2026) : deux fichiers JSON
/// dans Application Support, écriture atomique. Le serveur reste la référence ; ici, une file
/// d'attente (observations pas encore envoyées) et un cache pour afficher sans réseau.
///
/// Positions et dates d'une personne : les deux fichiers sont écrits en protection complète
/// (`completeFileProtection`, audit du 13 nov. 2026), illisibles tant que l'appareil est
/// verrouillé ; sans effet sur macOS. L'app ne les lit qu'au premier plan (aucun travail en
/// arrière-plan). Si la lecture échoue quand même (appareil verrouillé), rien n'est tenu pour
/// chargé et rien n'est écrit : une liste vide ne remplace jamais un fichier qu'on n'a pas pu lire.
actor LocalStore {
    /// Options d'écriture des deux fichiers.
    static var writingOptions: Data.WritingOptions { [.atomic, .completeFileProtection] }

    nonisolated struct ObservationsFile: Codable, Sendable {
        var version = 1
        var observations: [FieldObservation] = []
        /// Identifiants pas encore acceptés par `POST /observations`.
        var pending: [UUID] = []
    }

    nonisolated struct CoinsFile: Codable, Sendable {
        var version = 1
        var coins: [Coin] = []
        /// Base de la fusion (`CoinMerge`) : les coins que le serveur avait au dernier échange
        /// réussi (lecture de `GET /coins` ou `PUT /coins`). Absent d'un fichier d'avant la fusion.
        var synced: [Coin]? = nil
        /// Identifiant de l'app pour lequel `synced` vaut : la base d'un autre identifiant ne dit
        /// rien du serveur de celui-ci.
        var syncedFor: UUID? = nil
    }

    let directory: URL
    private var observationsFile = ObservationsFile()
    private var coinsFile = CoinsFile()
    private var loaded = false

    init(directory: URL) {
        self.directory = directory
    }

    static func defaultDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return support.appending(path: "Champis/field", directoryHint: .isDirectory)
    }

    private var observationsURL: URL { directory.appending(path: "observations.json") }
    private var coinsURL: URL { directory.appending(path: "coins.json") }

    /// Lit les fichiers une fois ; un fichier absent est une liste vide. Un fichier illisible
    /// (appareil verrouillé) lève l'erreur et laisse le magasin non chargé : la lecture sera
    /// retentée. Un fichier lu mais indéchiffrable lève aussi l'erreur, une seule fois : le magasin
    /// repart alors d'une liste vide, comme avant.
    func load() throws {
        guard !loaded else { return }
        let observations = try Self.read(ObservationsFile.self, at: observationsURL)
        let coins = try Self.read(CoinsFile.self, at: coinsURL)
        observationsFile = observations.value ?? ObservationsFile()
        coinsFile = coins.value ?? CoinsFile()
        loaded = true
        // fichiers écrits avant la protection complète : réécrits avec elle
        if observations.value != nil {
            try? write(observationsFile, to: observationsURL)
        }
        if coins.value != nil {
            try? write(coinsFile, to: coinsURL)
        }
        if let error = observations.corrupt ?? coins.corrupt {
            throw error
        }
    }

    // MARK: Observations

    /// Les plus récentes d'abord.
    var observations: [FieldObservation] {
        observationsFile.observations.sorted { $0.date > $1.date }
    }

    var pendingCount: Int { observationsFile.pending.count }

    var pendingObservations: [FieldObservation] {
        let pending = Set(observationsFile.pending)
        return observationsFile.observations.filter { pending.contains($0.id) }
    }

    /// Écrit d'abord sur l'appareil (la sortie se passe sans réseau), à envoyer ensuite.
    func add(_ observation: FieldObservation) throws {
        try load()
        observationsFile.observations.removeAll { $0.id == observation.id }
        observationsFile.observations.append(observation)
        if !observationsFile.pending.contains(observation.id) {
            observationsFile.pending.append(observation.id)
        }
        try write(observationsFile, to: observationsURL)
    }

    /// Retire une observation encore sur l'appareil (annulation dans les cinq secondes, lot 3).
    func remove(_ id: UUID) throws {
        try load()
        observationsFile.observations.removeAll { $0.id == id }
        observationsFile.pending.removeAll { $0 == id }
        try write(observationsFile, to: observationsURL)
    }

    func markSynced(_ ids: [UUID]) throws {
        try load()
        let done = Set(ids)
        observationsFile.pending.removeAll { done.contains($0) }
        try write(observationsFile, to: observationsURL)
    }

    /// Fusion par `id` avec ce que le serveur connaît : ses observations, plus celles de l'appareil
    /// qui attendent encore l'envoi (pour un même `id`, la version de l'appareil). Une observation
    /// déjà envoyée que le serveur n'a plus a été effacée ailleurs (« tout supprimer ») : elle part.
    func mergeRemote(_ remote: [FieldObservation]) throws {
        try load()
        let pending = Set(observationsFile.pending)
        let keep = observationsFile.observations.filter { pending.contains($0.id) }
        observationsFile.observations = remote.filter { !pending.contains($0.id) } + keep
        try write(observationsFile, to: observationsURL)
    }

    // MARK: Coins

    var coins: [Coin] { coinsFile.coins }

    /// Remplace la liste de l'appareil ; la base de la fusion ne change pas.
    func setCoins(_ coins: [Coin]) throws {
        try load()
        var next = coinsFile
        next.coins = coins
        try commit(next)
    }

    /// Ajoute un coin à la liste de l'appareil (ou le remplace, même `id`).
    func addCoin(_ coin: Coin) throws {
        try load()
        var next = coinsFile
        next.coins.removeAll { $0.id == coin.id }
        next.coins.append(coin)
        try commit(next)
    }

    /// Renomme un coin ; faux s'il n'est pas sur l'appareil.
    func renameCoin(_ id: UUID, to name: String) throws -> Bool {
        try load()
        guard let index = coinsFile.coins.firstIndex(where: { $0.id == id }) else { return false }
        var next = coinsFile
        next.coins[index].name = name
        try commit(next)
        return true
    }

    /// Retire un coin de l'appareil. La base le garde : elle est la pierre tombale qui empêche la
    /// fusion de le reprendre du serveur tant que la suppression n'y est pas arrivée.
    func removeCoin(_ id: UUID) throws {
        try load()
        var next = coinsFile
        next.coins.removeAll { $0.id == id }
        try commit(next)
    }

    /// Base de la fusion pour cet identifiant ; vide si rien n'a encore été échangé avec lui.
    func coinsBase(for user: UUID) -> [Coin] {
        coinsFile.syncedFor == user ? (coinsFile.synced ?? []) : []
    }

    /// Le serveur a maintenant cette liste (après un `PUT` réussi).
    func setCoinsBase(_ base: [Coin], for user: UUID) throws {
        try load()
        var next = coinsFile
        next.synced = base
        next.syncedFor = user
        try commit(next)
    }

    /// Fusionne la liste du serveur avec celle de l'appareil (`CoinMerge`) et l'écrit, d'un seul
    /// tenant : aucun ajout fait entre-temps n'est perdu. La base devient la liste du serveur.
    ///
    /// Si la base vaut pour un autre identifiant (l'identifiant de l'app a changé, conflit
    /// iCloud), les coins de l'appareil repartent sous de nouveaux `id` : ceux d'avant existent
    /// encore côté serveur sous l'ancien identifiant, et un `id` de coin y est unique.
    func mergeCoins(remote: [Coin], for user: UUID) throws -> CoinMerge.Outcome {
        try load()
        var local = coinsFile.coins
        if let previous = coinsFile.syncedFor, previous != user {
            local = local.map {
                Coin(name: $0.name, lat: $0.lat, lon: $0.lon, target: $0.target, altClass: $0.altClass, t: $0.t)
            }
        }
        let result = CoinMerge.merge(local: local, remote: remote, base: coinsBase(for: user))
        var next = coinsFile
        next.coins = result.coins
        next.synced = remote
        next.syncedFor = user
        try commit(next)
        return result
    }

    /// Écrit le fichier des coins, puis seulement garde l'état : un échec d'écriture ne laisse pas
    /// la mémoire en avance sur le disque.
    private func commit(_ next: CoinsFile) throws {
        try write(next, to: coinsURL)
        coinsFile = next
    }

    /// Droit à l'effacement : tout, après `DELETE /observations`.
    func removeAll() throws {
        try load()
        observationsFile = ObservationsFile()
        coinsFile = CoinsFile()
        try write(observationsFile, to: observationsURL)
        try write(coinsFile, to: coinsURL)
    }

    // MARK: Fichiers

    /// Résultat d'une lecture : la valeur, rien (fichier absent), ou l'erreur de décodage d'un
    /// fichier lu mais indéchiffrable.
    private nonisolated struct Loaded<T> {
        var value: T?
        var corrupt: (any Error)?
    }

    /// Une erreur de lecture du disque est levée (le fichier existe mais ne se lit pas) ; une
    /// erreur de décodage est rendue dans `corrupt`.
    private static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> Loaded<T> {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return Loaded() }
        let data = try Data(contentsOf: url)
        do {
            return Loaded(value: try JSONDecoder().decode(type, from: data))
        } catch {
            return Loaded(corrupt: error)
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: Self.writingOptions)
    }
}
