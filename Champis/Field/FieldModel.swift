import Foundation
import Observation
import UserNotifications

/// Retour terrain et mes coins (skill `field-feedback`) : observations écrites d'abord sur
/// l'appareil puis envoyées par lots à `POST /observations` (idempotent par `id`), coins
/// synchronisés en liste complète par `PUT /coins`. Pas de rafraîchissement en arrière-plan : les
/// notifications sont calculées et envoyées par le backend.
///
/// Fusion au démarrage (décision du 13 nov. 2026) : `PUT /coins` remplace la liste du serveur,
/// donc l'app lit d'abord `GET /coins` et `GET /observations` et fusionne avec l'appareil
/// (`CoinMerge`, `LocalStore.mergeRemote`). Aucun `PUT` ne part tant que cette première lecture
/// n'a pas réussi : hors ligne, les ajouts restent sur l'appareil et attendent.
@Observable
final class FieldModel {
    static let batchSize = 200

    private(set) var observations: [FieldObservation] = []
    private(set) var pendingCount = 0
    private(set) var coins: [Coin] = []
    private(set) var coinScores: [UUID: ScoredCoin] = [:]
    private(set) var coinsToday: String?
    /// Confirmation en clair (« Observations et coins effacés ») ; les échecs vont dans `problem`.
    private(set) var status: String?
    /// Échec en clair avec sa reprise (étape B4, 6 nov. 2026) : rien n'est perdu, « Réessayer » relance.
    private(set) var problem: Problem?
    private(set) var isSyncing = false
    private(set) var userID: UUID?
    /// Observations annulables (« Noté : rien trouvé », lot 3) : pas encore envoyées, retirables.
    private(set) var undoable: [UUID] = []
    /// Délai pendant lequel « Annuler » est proposé avant l'envoi ; raccourci par les tests.
    @ObservationIgnored var undoWindow: Duration = .seconds(5)
    @ObservationIgnored private var undoTask: Task<Void, Never>?

    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private let identity: IdentityProvider
    @ObservationIgnored private(set) var api: ChampisAPI
    /// Désactivé par les tests : la demande système attendrait une réponse.
    @ObservationIgnored var asksNotificationPermission = true
    /// Ce que « Réessayer » relance pour `problem`.
    @ObservationIgnored private var problemRetry: Retry?
    /// Vrai une fois les coins et les observations du serveur lus et fusionnés avec l'appareil,
    /// pour cette adresse d'API et depuis ce lancement : avant, aucun `PUT /coins`.
    @ObservationIgnored private(set) var remoteMerged = false
    /// Une synchronisation des coins est en cours ; une demande arrivée entre-temps la relance.
    @ObservationIgnored private var isSyncingCoins = false
    @ObservationIgnored private var coinSyncRequested = false

    /// Ce que « Réessayer » relance (étape B4).
    nonisolated enum Retry: Equatable, Sendable {
        case start
        case sync
        case delete
        case pushCoins
        case coinScores
    }

    init(api: ChampisAPI, store: LocalStore, identity: IdentityProvider) {
        self.api = api
        self.store = store
        self.identity = identity
    }

    /// Build de développement : passerelle APNs sandbox côté serveur.
    nonisolated static var isSandboxBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Charge le local, résout l'identifiant, envoie ce qui attend.
    func start(api: ChampisAPI) async {
        if api.baseURL != self.api.baseURL || api.trustedHost != self.api.trustedHost {
            // une autre adresse : ce qu'elle sait n'a pas encore été lu
            remoteMerged = false
        }
        self.api = api
        do {
            try await store.load()
        } catch {
            fail(Problem("Les observations de l'appareil n'ont pas pu être lues", error: error), retry: .start)
        }
        await resolveIdentity()
        await refreshFromStore()
        // d'abord lire et fusionner ce que le serveur connaît, ensuite envoyer ce qui attend
        await synchronizeCoins(reportFailure: false)
        await sync()
    }

    /// Lit l'identifiant de l'app, ou le crée si le trousseau dit qu'il n'en a pas, hors du fil
    /// principal. Une erreur du trousseau se dit en clair, avec « Réessayer » : aucun identifiant
    /// de rechange n'est créé, observations et coins restent sur l'appareil en attendant.
    func resolveIdentity() async {
        guard userID == nil else { return }
        do {
            userID = try await Identity.resolveInBackground(identity)
        } catch {
            fail(
                Problem(
                    "L'identifiant de l'app n'a pas pu être lu : observations et coins restent sur l'appareil",
                    detail: "trousseau : \(Problem.technical(error))"
                ),
                retry: .start
            )
        }
    }

    private func refreshFromStore() async {
        observations = await store.observations
        pendingCount = await store.pendingCount
        coins = await store.coins
    }

    // MARK: - Observations

    /// Enregistre sur l'appareil puis tente l'envoi ; sans réseau, l'observation attend.
    func record(
        species: String, latitude: Double, longitude: Double, accuracyM: Double?, date: String,
        found: Bool, quantity: Int?
    ) async {
        let observation = FieldObservation(
            species: species, lat: latitude, lon: longitude, accuracyM: accuracyM, date: date,
            found: found, quantity: quantity
        )
        do {
            try await store.add(observation)
        } catch {
            fail(Problem("L'observation n'a pas pu être enregistrée sur l'appareil", error: error, retryable: false))
            return
        }
        await refreshFromStore()
        await sync()
    }

    /// « Rien trouvé ici » en une tape (lot 3) : une observation négative par espèce, enregistrée
    /// tout de suite, annulable pendant `undoWindow`, envoyée ensuite.
    /// `accuracyM` : précision GPS quand le point est une position mesurée ; `nil` pour un point touché.
    func recordNotFound(species: [String], latitude: Double, longitude: Double, accuracyM: Double? = nil) async {
        var ids: [UUID] = []
        for sid in species {
            let observation = FieldObservation(
                species: sid, lat: latitude, lon: longitude, accuracyM: accuracyM, date: Self.isoDay(),
                found: false, quantity: nil
            )
            do {
                try await store.add(observation)
                ids.append(observation.id)
            } catch {
                fail(Problem("L'observation n'a pas pu être enregistrée sur l'appareil", error: error, retryable: false))
            }
        }
        await refreshFromStore()
        guard !ids.isEmpty else { return }
        undoTask?.cancel()
        undoable = ids
        let window = undoWindow
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled, let self else { return }
            undoable = []
            await sync()
        }
    }

    /// Retire ce qui vient d'être noté « rien trouvé », tant que l'envoi n'a pas eu lieu.
    func undoNotFound() async {
        undoTask?.cancel()
        let ids = undoable
        undoable = []
        for id in ids {
            try? await store.remove(id)
        }
        await refreshFromStore()
    }

    /// Envoie les observations en attente par lots ; réessayé à chaque démarrage et enregistrement.
    /// Ce qui est encore annulable attend la fin de son délai.
    func sync() async {
        // adresse d'API non officielle : lecture seule, les observations attendent sur l'appareil
        guard let userID, api.isOfficial, !isSyncing else { return }
        let held = Set(undoable)
        let pending = await store.pendingObservations.filter { !held.contains($0.id) }
        guard !pending.isEmpty else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            var start = 0
            while start < pending.count {
                let batch = Array(pending[start..<min(start + Self.batchSize, pending.count)])
                _ = try await api.postObservations(batch, user: userID)
                try await store.markSynced(batch.map(\.id))
                start += Self.batchSize
            }
            clear(.sync)
        } catch {
            fail(Problem("Observations pas encore envoyées, elles restent sur l'appareil", error: error), retry: .sync)
        }
        await refreshFromStore()
    }

    /// Droit à l'effacement : le serveur d'abord, le local ensuite ; en cas d'échec, rien n'est perdu.
    func deleteAll() async {
        guard let userID else { return }
        guard api.isOfficial else {
            // rien n'est effacé de l'appareil sans l'être du serveur
            fail(Problem(
                "Rien n'a été effacé : revenez à l'adresse officielle de l'API pour effacer aussi vos données du serveur",
                detail: Problem.technical(ChampisAPI.Failure.readOnly), retryable: false
            ))
            return
        }
        do {
            // Les identifiants mis de côté (deux appareils avaient créé le leur avant que iCloud ne
            // les réunisse) sont effacés du serveur eux aussi, puis oubliés un à un.
            for old in identity.memory.retired() where old != userID {
                _ = try await api.deleteObservations(user: old)
                identity.memory.setRetired(identity.memory.retired().filter { $0 != old })
            }
            _ = try await api.deleteObservations(user: userID)
            try await store.removeAll()
            coinScores = [:]
            clear(.delete)
            status = "Observations et coins effacés"
        } catch {
            fail(Problem("L'effacement n'a pas abouti : le serveur n'a pas pu être joint", error: error), retry: .delete)
        }
        await refreshFromStore()
    }

    // MARK: - Coins

    /// Ajoute un coin sur l'appareil puis synchronise ; la permission de notification est demandée
    /// au premier coin, jamais au lancement.
    func addCoin(name: String, latitude: Double, longitude: Double, target: String, altClass: Int, t: [String: Double]) async {
        let first = coins.isEmpty
        let coin = Coin(name: name, lat: latitude, lon: longitude, target: target, altClass: altClass, t: t)
        do {
            try await store.addCoin(coin)
        } catch {
            fail(Problem("Le coin n'a pas pu être enregistré sur l'appareil", error: error, retryable: false))
            return
        }
        await refreshFromStore()
        if first, asksNotificationPermission {
            await Self.requestNotificationPermission()
        }
        await pushCoins()
    }

    /// Renomme un coin sur l'appareil puis synchronise.
    func renameCoin(_ id: UUID, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            guard try await store.renameCoin(id, to: trimmed) else { return }
        } catch {
            fail(Problem("Le coin n'a pas pu être renommé", error: error, retryable: false))
            return
        }
        await refreshFromStore()
        await pushCoins()
    }

    /// Complète le terrain par espèce de coins existants, puis synchronise (18 nov. 2026). Rien
    /// n'est envoyé si rien ne change.
    func setCoinTerrains(_ updates: [UUID: [String: Double]]) async {
        guard !updates.isEmpty else { return }
        do {
            guard try await store.setCoinTerrains(updates) else { return }
        } catch {
            fail(Problem("Les coins n'ont pas pu être mis à jour sur l'appareil", error: error, retryable: false))
            return
        }
        await refreshFromStore()
        await pushCoins()
    }

    func removeCoin(_ id: UUID) async {
        do {
            try await store.removeCoin(id)
        } catch {
            fail(Problem("Le coin n'a pas pu être supprimé", error: error, retryable: false))
            return
        }
        coinScores[id] = nil
        await refreshFromStore()
        await pushCoins()
    }

    /// Après un changement de la liste : synchronise, et dit en clair si le serveur ne répond pas.
    private func pushCoins() async {
        await synchronizeCoins(reportFailure: true)
    }

    /// Coins : lecture du serveur et fusion si elle n'a pas encore eu lieu, puis `PUT /coins` de la
    /// liste de l'appareil tant qu'elle diffère de ce que le serveur a (sans jeton pour l'instant,
    /// enregistrement APNs à venir). Aucun `PUT` avant une première lecture réussie.
    ///
    /// `reportFailure` : au démarrage (`false`), un échec ne se dit que si des changements de
    /// l'appareil attendent ; sans réseau et sans rien à envoyer, l'app ne dit rien.
    private func synchronizeCoins(reportFailure: Bool) async {
        guard let userID, api.isOfficial else { return }
        guard !isSyncingCoins else {
            coinSyncRequested = true
            return
        }
        isSyncingCoins = true
        coinSyncRequested = false
        let api = api
        do {
            if !remoteMerged {
                try await mergeRemote(user: userID, api: api)
            }
            var sent = false
            while true {
                let list = await store.coins
                let base = await store.coinsBase(for: userID)
                if CoinMerge.same(list, base) { break }
                _ = try await api.putCoins(list, apnsToken: nil, sandbox: Self.isSandboxBuild, user: userID)
                try await store.setCoinsBase(list, for: userID)
                sent = true
            }
            clear(.pushCoins)
            await refreshFromStore()
            if sent {
                await refreshCoinScores()
            }
        } catch {
            await refreshFromStore()
            let list = await store.coins
            let base = await store.coinsBase(for: userID)
            // des changements de l'appareil attendent : à dire même au démarrage
            if reportFailure || !CoinMerge.same(list, base) {
                fail(Problem("Coins pas encore envoyés au serveur : pas de notification d'ici là", error: error), retry: .pushCoins)
            }
            coinSyncRequested = false
        }
        isSyncingCoins = false
        if coinSyncRequested {
            await synchronizeCoins(reportFailure: reportFailure)
        }
    }

    /// Première lecture du serveur : `GET /coins` et `GET /observations`, fusionnés avec l'appareil.
    /// Les scores de la même réponse servent tout de suite.
    private func mergeRemote(user: UUID, api: ChampisAPI) async throws {
        let snapshot = try await api.coinsSnapshot(user: user)
        let remote = try await api.observations(user: user)
        _ = try await store.mergeCoins(remote: snapshot.list, for: user)
        try await store.mergeRemote(remote.observations)
        remoteMerged = true
        adopt(snapshot.scored)
        await refreshFromStore()
    }

    /// Scores du jour de `GET /coins`.
    private func adopt(_ response: CoinsResponse) {
        coinsToday = response.today
        var scores: [UUID: ScoredCoin] = [:]
        for coin in response.coins {
            scores[coin.id] = coin
        }
        coinScores = scores
    }

    func refreshCoinScores() async {
        guard let userID, api.isOfficial, !coins.isEmpty else { return }
        do {
            adopt(try await api.coins(user: userID))
            clear(.coinScores)
        } catch {
            fail(Problem("Score des coins indisponible", error: error), retry: .coinScores)
        }
    }

    // MARK: - Erreurs en clair (étape B4)

    private func fail(_ problem: Problem, retry: Retry? = nil) {
        self.problem = problem
        problemRetry = retry
        status = nil
    }

    /// Une opération a réussi : son message d'échec, s'il est affiché, disparaît.
    private func clear(_ retry: Retry) {
        if problemRetry == retry {
            problem = nil
            problemRetry = nil
        }
    }

    /// « Réessayer » sous un message des coins ou des observations.
    func retry() async {
        let retry = problemRetry
        problem = nil
        problemRetry = nil
        switch retry {
        case .start: await start(api: api)
        case .sync: await sync()
        case .delete: await deleteAll()
        case .pushCoins: await pushCoins()
        case .coinScores: await refreshCoinScores()
        case nil: break
        }
    }

    static func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Jour civil local, ISO.
    nonisolated static func isoDay(_ date: Date = .now, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
