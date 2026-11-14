import Foundation
import Security
import Synchronization

/// Identifiant de l'app (skill `field-feedback`) : un UUID aléatoire généré au premier lancement,
/// envoyé en en-tête `X-Champis-User` de chaque appel à l'API (obligatoire pour les observations et
/// les coins ; pour le reste, le serveur n'en garde qu'une empreinte hachée par jour, lot BO2).
/// Aucun compte, aucun mail. Le trousseau synchronisé iCloud le fait survivre à un changement
/// d'appareil ; qui le perd perd ses épingles et ses coins, le serveur garde des lignes anonymes.
///
/// Règles (audit du 13 nov. 2026) : un identifiant n'est créé que si le trousseau dit qu'il n'en a
/// pas (`errSecItemNotFound`) ; toute autre erreur remonte (message, « Réessayer »), sans repli
/// vers un nouvel identifiant, qui ferait perdre épingles et coins. Un identifiant déjà dans le
/// trousseau n'est jamais écrasé. Quand l'identifiant lu n'est plus le dernier connu (deux
/// appareils ont créé le leur avant que iCloud ne les réunisse), l'ancien est mis de côté pour
/// que « Supprimer mes observations et mes coins » efface les deux côté serveur.
nonisolated protocol IdentityStore: Sendable {
    /// L'identifiant enregistré ; `nil` seulement s'il n'y en a pas. Toute autre impossibilité de
    /// lire lève une erreur.
    func load() throws -> UUID?
    /// Ajoute l'identifiant ; `IdentityError.duplicate` s'il y en a déjà un, qui n'est pas remplacé.
    func save(_ id: UUID) throws
}

nonisolated enum IdentityError: Error, Equatable {
    case keychain(OSStatus)
    /// Un identifiant est déjà enregistré : il fait foi, on ne l'écrase pas.
    case duplicate
    /// L'élément du trousseau existe mais ne contient pas un UUID.
    case unreadable
}

/// Trousseau, élément synchronisé iCloud.
nonisolated struct KeychainIdentityStore: IdentityStore {
    let service: String
    let account: String

    init(service: String = "fr.adhumi.champis", account: String = "user-id") {
        self.service = service
        self.account = account
    }

    private var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
        ]
    }

    func load() throws -> UUID? {
        var query = base
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw IdentityError.keychain(status) }
        guard let data = item as? Data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else {
            throw IdentityError.unreadable
        }
        return id
    }

    /// `SecItemAdd` seul : sur doublon, l'élément présent reste tel quel (jamais de `SecItemUpdate`).
    func save(_ id: UUID) throws {
        let value = Data(id.uuidString.utf8)
        var attributes = base
        attributes[kSecValueData as String] = value
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem { throw IdentityError.duplicate }
        guard status == errSecSuccess else { throw IdentityError.keychain(status) }
    }
}

/// Tests et aperçus : un magasin en mémoire, qui refuse comme le trousseau d'écraser un identifiant.
nonisolated final class MemoryIdentityStore: IdentityStore {
    private let stored: Mutex<UUID?>

    init(_ id: UUID? = nil) {
        stored = Mutex(id)
    }

    func load() throws -> UUID? {
        stored.withLock { $0 }
    }

    func save(_ id: UUID) throws {
        let added = stored.withLock { current -> Bool in
            guard current == nil else { return false }
            current = id
            return true
        }
        if !added { throw IdentityError.duplicate }
    }
}

/// Ce que l'app retient hors du trousseau : le dernier identifiant lu ou créé, et ceux qu'un
/// autre a remplacés (mis de côté jusqu'à leur effacement côté serveur).
nonisolated protocol IdentityMemory: Sendable {
    func lastKnown() -> UUID?
    func setLastKnown(_ id: UUID)
    func retired() -> [UUID]
    func setRetired(_ ids: [UUID])
}

/// `UserDefaults`. La clé du dernier connu est celle de l'ancien magasin de repli : un identifiant
/// qui ne vivait que là (trousseau refusé à l'époque) reste celui de l'app.
nonisolated struct DefaultsIdentityMemory: IdentityMemory {
    let key: String
    let retiredKey: String

    init(key: String = "champis.userID", retiredKey: String = "champis.retiredUserIDs") {
        self.key = key
        self.retiredKey = retiredKey
    }

    func lastKnown() -> UUID? {
        UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    func setLastKnown(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: key)
    }

    func retired() -> [UUID] {
        (UserDefaults.standard.stringArray(forKey: retiredKey) ?? []).compactMap(UUID.init(uuidString:))
    }

    func setRetired(_ ids: [UUID]) {
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: retiredKey)
    }
}

/// Tests et aperçus.
nonisolated final class VolatileIdentityMemory: IdentityMemory {
    private struct State {
        var last: UUID?
        var retired: [UUID] = []
    }

    private let state: Mutex<State>

    init(lastKnown: UUID? = nil, retired: [UUID] = []) {
        state = Mutex(State(last: lastKnown, retired: retired))
    }

    func lastKnown() -> UUID? {
        state.withLock { $0.last }
    }

    func setLastKnown(_ id: UUID) {
        state.withLock { $0.last = id }
    }

    func retired() -> [UUID] {
        state.withLock { $0.retired }
    }

    func setRetired(_ ids: [UUID]) {
        state.withLock { $0.retired = ids }
    }
}

/// Où l'identité se lit et se retient : le trousseau et `UserDefaults` dans l'app, la mémoire dans
/// les tests.
nonisolated struct IdentityProvider: Sendable {
    let store: any IdentityStore
    let memory: any IdentityMemory

    static var system: IdentityProvider {
        IdentityProvider(store: KeychainIdentityStore(), memory: DefaultsIdentityMemory())
    }

    /// Tests et aperçus : rien ne sort de la mémoire du processus.
    static func inMemory(_ id: UUID? = nil) -> IdentityProvider {
        IdentityProvider(store: MemoryIdentityStore(id), memory: VolatileIdentityMemory())
    }
}

nonisolated enum Identity {
    /// L'identifiant de l'app.
    ///
    /// - Le magasin en a un : c'est lui. S'il diffère du dernier connu, celui-ci est mis de côté.
    /// - Le magasin dit qu'il n'en a pas : le dernier connu y est remis s'il existe, sinon un
    ///   identifiant est créé. Si le magasin en a reçu un entre-temps (doublon), c'est celui du
    ///   magasin qui fait foi, il n'est pas écrasé.
    /// - Le magasin est en erreur : jamais de nouvel identifiant. Le dernier connu sert s'il
    ///   existe, sinon l'erreur remonte.
    static func resolve(_ provider: IdentityProvider) throws -> UUID {
        let (store, memory) = (provider.store, provider.memory)
        let found: UUID?
        do {
            found = try store.load()
        } catch {
            if let known = memory.lastKnown() {
                return known
            }
            throw error
        }
        if let found {
            remember(found, in: memory)
            return found
        }
        let candidate = memory.lastKnown() ?? UUID()
        do {
            try store.save(candidate)
        } catch IdentityError.duplicate {
            guard let existing = try store.load() else { throw IdentityError.duplicate }
            remember(existing, in: memory)
            return existing
        }
        remember(candidate, in: memory)
        return candidate
    }

    /// Note `id` comme dernier connu ; le précédent, s'il diffère, est mis de côté.
    static func remember(_ id: UUID, in memory: any IdentityMemory) {
        var retired = memory.retired()
        if let last = memory.lastKnown(), last != id, !retired.contains(last) {
            retired.append(last)
        }
        retired.removeAll { $0 == id }
        if retired != memory.retired() {
            memory.setRetired(retired)
        }
        memory.setLastKnown(id)
    }

    /// `resolve` hors du fil principal : la lecture du trousseau est synchrone et peut attendre.
    @concurrent
    static func resolveInBackground(_ provider: IdentityProvider) async throws -> UUID {
        try resolve(provider)
    }
}
