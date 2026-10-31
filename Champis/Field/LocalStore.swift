import Foundation

/// Stockage local des observations et des coins (décision du 31 oct. 2026) : deux fichiers JSON
/// dans Application Support, écriture atomique. Le serveur reste la référence ; ici, une file
/// d'attente (observations pas encore envoyées) et un cache pour afficher sans réseau.
actor LocalStore {
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

    /// Lit les fichiers une fois ; un fichier absent est une liste vide.
    func load() throws {
        guard !loaded else { return }
        loaded = true
        observationsFile = try Self.read(ObservationsFile.self, at: observationsURL) ?? ObservationsFile()
        coinsFile = try Self.read(CoinsFile.self, at: coinsURL) ?? CoinsFile()
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
        observationsFile.observations.removeAll { $0.id == observation.id }
        observationsFile.observations.append(observation)
        if !observationsFile.pending.contains(observation.id) {
            observationsFile.pending.append(observation.id)
        }
        try write(observationsFile, to: observationsURL)
    }

    func markSynced(_ ids: [UUID]) throws {
        let done = Set(ids)
        observationsFile.pending.removeAll { done.contains($0) }
        try write(observationsFile, to: observationsURL)
    }

    /// Ce que le serveur connaît remplace ce qui a déjà été envoyé ; les locales en attente restent.
    func mergeRemote(_ remote: [FieldObservation]) throws {
        let pending = Set(observationsFile.pending)
        let remoteIDs = Set(remote.map(\.id))
        let keep = observationsFile.observations.filter { pending.contains($0.id) && !remoteIDs.contains($0.id) }
        observationsFile.observations = remote + keep
        try write(observationsFile, to: observationsURL)
    }

    // MARK: Coins

    var coins: [Coin] { coinsFile.coins }

    func setCoins(_ coins: [Coin]) throws {
        coinsFile.coins = coins
        try write(coinsFile, to: coinsURL)
    }

    /// Droit à l'effacement : tout, après `DELETE /observations`.
    func removeAll() throws {
        observationsFile = ObservationsFile()
        coinsFile = CoinsFile()
        try write(observationsFile, to: observationsURL)
        try write(coinsFile, to: coinsURL)
    }

    // MARK: Fichiers

    private static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
