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

    /// Ce que le serveur connaît remplace ce qui a déjà été envoyé ; les locales en attente restent.
    func mergeRemote(_ remote: [FieldObservation]) throws {
        try load()
        let pending = Set(observationsFile.pending)
        let remoteIDs = Set(remote.map(\.id))
        let keep = observationsFile.observations.filter { pending.contains($0.id) && !remoteIDs.contains($0.id) }
        observationsFile.observations = remote + keep
        try write(observationsFile, to: observationsURL)
    }

    // MARK: Coins

    var coins: [Coin] { coinsFile.coins }

    func setCoins(_ coins: [Coin]) throws {
        try load()
        coinsFile.coins = coins
        try write(coinsFile, to: coinsURL)
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
    private struct Loaded<T> {
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
