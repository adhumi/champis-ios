import Foundation
import Observation
import UserNotifications

/// Retour terrain et mes coins (skill `field-feedback`) : observations écrites d'abord sur
/// l'appareil puis envoyées par lots à `POST /observations` (idempotent par `id`), coins
/// synchronisés en liste complète par `PUT /coins`. Pas de rafraîchissement en arrière-plan : les
/// notifications sont calculées et envoyées par le backend.
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
    @ObservationIgnored private let identityStores: [any IdentityStore]
    @ObservationIgnored private(set) var api: ChampisAPI
    /// Désactivé par les tests : la demande système attendrait une réponse.
    @ObservationIgnored var asksNotificationPermission = true
    /// Ce que « Réessayer » relance pour `problem`.
    @ObservationIgnored private var problemRetry: Retry?

    /// Ce que « Réessayer » relance (étape B4).
    nonisolated enum Retry: Equatable, Sendable {
        case start
        case sync
        case pull
        case delete
        case pushCoins
        case coinScores
    }

    init(api: ChampisAPI, store: LocalStore, identityStores: [any IdentityStore]) {
        self.api = api
        self.store = store
        self.identityStores = identityStores
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
        self.api = api
        do {
            try await store.load()
        } catch {
            fail(Problem("Les observations de l'appareil n'ont pas pu être lues", error: error), retry: .start)
        }
        if userID == nil {
            userID = Identity.userID(from: identityStores)
            if userID == nil {
                fail(
                    Problem("L'app n'a pas pu créer son identifiant : observations et coins restent sur l'appareil", detail: "trousseau et UserDefaults indisponibles"),
                    retry: .start
                )
            }
        }
        await refreshFromStore()
        await sync()
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
        guard let userID, !isSyncing else { return }
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

    /// Reprend du serveur ce qu'il connaît (changement d'appareil, réinstallation).
    func pullRemote() async {
        guard let userID else { return }
        do {
            let response = try await api.observations(user: userID)
            try await store.mergeRemote(response.observations)
            clear(.pull)
            await refreshFromStore()
        } catch {
            fail(Problem("Vos observations n'ont pas pu être reprises du serveur", error: error), retry: .pull)
        }
    }

    /// Droit à l'effacement : le serveur d'abord, le local ensuite ; en cas d'échec, rien n'est perdu.
    func deleteAll() async {
        guard let userID else { return }
        do {
            _ = try await api.deleteObservations(user: userID)
            try await store.removeAll()
            coinScores = [:]
            clear(.delete)
            status = "Observations et coins effacés"
        } catch {
            fail(Problem("Rien n'a été effacé : le serveur n'a pas pu être joint", error: error), retry: .delete)
        }
        await refreshFromStore()
    }

    // MARK: - Coins

    /// Ajoute un coin et renvoie la liste complète ; la permission de notification est demandée
    /// au premier coin, jamais au lancement.
    func addCoin(name: String, latitude: Double, longitude: Double, target: String, altClass: Int, t: [String: Double]) async {
        let first = coins.isEmpty
        var list = coins
        list.append(Coin(name: name, lat: latitude, lon: longitude, target: target, altClass: altClass, t: t))
        do {
            try await store.setCoins(list)
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

    /// Renomme un coin ; la liste complète repart au serveur.
    func renameCoin(_ id: UUID, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = coins.firstIndex(where: { $0.id == id }) else { return }
        var list = coins
        list[index].name = trimmed
        do {
            try await store.setCoins(list)
        } catch {
            fail(Problem("Le coin n'a pas pu être renommé", error: error, retryable: false))
            return
        }
        await refreshFromStore()
        await pushCoins()
    }

    func removeCoin(_ id: UUID) async {
        let list = coins.filter { $0.id != id }
        do {
            try await store.setCoins(list)
        } catch {
            fail(Problem("Le coin n'a pas pu être supprimé", error: error, retryable: false))
            return
        }
        coinScores[id] = nil
        await refreshFromStore()
        await pushCoins()
    }

    /// `PUT /coins` en liste complète, sans jeton pour l'instant (enregistrement APNs à venir).
    private func pushCoins() async {
        guard let userID else { return }
        do {
            _ = try await api.putCoins(coins, apnsToken: nil, sandbox: Self.isSandboxBuild, user: userID)
            clear(.pushCoins)
            await refreshCoinScores()
        } catch {
            fail(Problem("Coins pas encore envoyés au serveur : pas de notification d'ici là", error: error), retry: .pushCoins)
        }
    }

    func refreshCoinScores() async {
        guard let userID, !coins.isEmpty else { return }
        do {
            let response = try await api.coins(user: userID)
            coinsToday = response.today
            var scores: [UUID: ScoredCoin] = [:]
            for coin in response.coins {
                scores[coin.id] = coin
            }
            coinScores = scores
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
        case .pull: await pullRemote()
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
