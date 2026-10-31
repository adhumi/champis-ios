import Foundation
import Security
import Synchronization

/// Identifiant de l'app (skill `field-feedback`) : un UUID aléatoire généré au premier lancement,
/// envoyé en en-tête `X-Champis-User` de chaque appel qui touche les observations ou les coins.
/// Aucun compte, aucun mail. Le trousseau synchronisé iCloud le fait survivre à un changement
/// d'appareil ; qui le perd perd ses épingles et ses coins, le serveur garde des lignes anonymes.
nonisolated protocol IdentityStore: Sendable {
    func load() throws -> UUID?
    func save(_ id: UUID) throws
}

nonisolated enum IdentityError: Error {
    case keychain(OSStatus)
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
        guard let data = item as? Data, let text = String(data: data, encoding: .utf8) else { return nil }
        return UUID(uuidString: text)
    }

    func save(_ id: UUID) throws {
        let value = Data(id.uuidString.utf8)
        var attributes = base
        attributes[kSecValueData as String] = value
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: value] as CFDictionary)
            guard update == errSecSuccess else { throw IdentityError.keychain(update) }
            return
        }
        guard status == errSecSuccess else { throw IdentityError.keychain(status) }
    }
}

/// Repli quand le trousseau refuse (macOS sans droits, simulateur) : l'identifiant reste alors
/// propre à l'appareil.
nonisolated struct DefaultsIdentityStore: IdentityStore {
    let key: String

    init(key: String = "champis.userID") {
        self.key = key
    }

    func load() throws -> UUID? {
        UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    func save(_ id: UUID) throws {
        UserDefaults.standard.set(id.uuidString, forKey: key)
    }
}

/// Tests et aperçus.
nonisolated final class MemoryIdentityStore: IdentityStore {
    private let stored: Mutex<UUID?>

    init(_ id: UUID? = nil) {
        stored = Mutex(id)
    }

    func load() throws -> UUID? {
        stored.withLock { $0 }
    }

    func save(_ id: UUID) throws {
        stored.withLock { $0 = id }
    }
}

nonisolated enum Identity {
    /// L'identifiant du premier magasin qui répond : lu s'il existe, sinon créé et enregistré.
    static func userID(from stores: [any IdentityStore]) -> UUID? {
        for store in stores {
            if let id = try? store.load() {
                return id
            }
            let id = UUID()
            if (try? store.save(id)) != nil {
                return id
            }
        }
        return nil
    }
}
