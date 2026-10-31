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
    private(set) var status: String?
    private(set) var isSyncing = false
    private(set) var userID: UUID?

    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private let identityStores: [any IdentityStore]
    @ObservationIgnored private(set) var api: ChampisAPI
    /// Désactivé par les tests : la demande système attendrait une réponse.
    @ObservationIgnored var asksNotificationPermission = true

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
            status = "Stockage local illisible : \(error.localizedDescription)"
        }
        if userID == nil {
            userID = Identity.userID(from: identityStores)
            if userID == nil {
                status = "Identifiant de l'app impossible à créer"
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
            status = "FieldObservation non enregistrée : \(error.localizedDescription)"
            return
        }
        await refreshFromStore()
        await sync()
    }

    /// Envoie les observations en attente par lots ; réessayé à chaque démarrage et enregistrement.
    func sync() async {
        guard let userID, !isSyncing else { return }
        let pending = await store.pendingObservations
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
            status = nil
        } catch {
            status = "Envoi différé : \(error.localizedDescription)"
        }
        await refreshFromStore()
    }

    /// Reprend du serveur ce qu'il connaît (changement d'appareil, réinstallation).
    func pullRemote() async {
        guard let userID else { return }
        do {
            let response = try await api.observations(user: userID)
            try await store.mergeRemote(response.observations)
            await refreshFromStore()
        } catch {
            status = "Observations du serveur indisponibles : \(error.localizedDescription)"
        }
    }

    /// Droit à l'effacement : le serveur d'abord, le local ensuite ; en cas d'échec, rien n'est perdu.
    func deleteAll() async {
        guard let userID else { return }
        do {
            _ = try await api.deleteObservations(user: userID)
            try await store.removeAll()
            coinScores = [:]
            status = "Observations et coins effacés"
        } catch {
            status = "Suppression impossible : \(error.localizedDescription)"
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
            status = "Coin non enregistré : \(error.localizedDescription)"
            return
        }
        await refreshFromStore()
        if first, asksNotificationPermission {
            await Self.requestNotificationPermission()
        }
        await pushCoins()
    }

    func removeCoin(_ id: UUID) async {
        let list = coins.filter { $0.id != id }
        do {
            try await store.setCoins(list)
        } catch {
            status = "Coin non supprimé : \(error.localizedDescription)"
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
            await refreshCoinScores()
        } catch {
            status = "Coins non synchronisés : \(error.localizedDescription)"
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
        } catch {
            status = "Score des coins indisponible : \(error.localizedDescription)"
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
