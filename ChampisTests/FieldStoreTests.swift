import Foundation
import Testing
@testable import Champis

struct FieldStoreTests {
    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "champis-field-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test("Observations : écriture locale d'abord, file d'attente, fusion avec le serveur, persistance")
    func observations() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(directory: directory)
        try await store.load()
        #expect(await store.observations.isEmpty)
        #expect(await store.pendingCount == 0)

        let older = FieldObservation(species: "boletus_edulis", lat: 47.0, lon: 6.0, date: "2026-10-29", found: false, quantity: 2)
        let newer = FieldObservation(species: "boletus_edulis", lat: 47.1, lon: 6.1, accuracyM: 8, date: "2026-10-31", found: true, quantity: 3)
        try await store.add(older)
        try await store.add(newer)
        #expect(older.quantity == nil)  // rien trouvé : la quantité n'a pas de sens
        #expect(await store.observations.map(\.date) == ["2026-10-31", "2026-10-29"])
        #expect(await store.pendingCount == 2)

        try await store.markSynced([older.id])
        #expect(await store.pendingCount == 1)
        #expect(await store.pendingObservations.map(\.id) == [newer.id])

        // retrait d'une observation annulée (lot 3) : disparue de la liste et de la file, persistant
        let undone = FieldObservation(species: "boletus_edulis", lat: 47.2, lon: 6.2, date: "2026-11-01", found: false, quantity: nil)
        try await store.add(undone)
        #expect(await store.pendingCount == 2)
        try await store.remove(undone.id)
        #expect(await store.observations.map(\.id) == [newer.id, older.id])
        #expect(await store.pendingObservations.map(\.id) == [newer.id])
        let reopened = LocalStore(directory: directory)
        try await reopened.load()
        #expect(await reopened.observations.count == 2)

        // le serveur connaît l'ancienne (avec une autre précision) et une inconnue ; la locale en attente reste
        var remoteOlder = older
        remoteOlder.accuracyM = 25
        let remoteOther = FieldObservation(species: "boletus_aereus", lat: 46.0, lon: 5.0, date: "2026-10-20", found: true, quantity: 1)
        try await store.mergeRemote([remoteOlder, remoteOther])
        let merged = await store.observations
        #expect(merged.map(\.id) == [newer.id, older.id, remoteOther.id])
        #expect(merged.first { $0.id == older.id }?.accuracyM == 25)
        #expect(await store.pendingCount == 1)

        // nouvelle instance : tout relu depuis le disque
        let again = LocalStore(directory: directory)
        try await again.load()
        #expect(await again.observations.count == 3)
        #expect(await again.pendingObservations.map(\.id) == [newer.id])

        try await again.removeAll()
        #expect(await again.observations.isEmpty)
        let third = LocalStore(directory: directory)
        try await third.load()
        #expect(await third.observations.isEmpty)
    }

    @Test("Coins : liste complète remplacée, relue")
    func coins() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(directory: directory)
        try await store.load()
        let coin = Coin(name: "Hêtraie du col", lat: 47.0, lon: 6.0, target: "cepes", altClass: 750, t: ["boletus_edulis": 0.8])
        try await store.setCoins([coin])
        #expect(await store.coins == [coin])
        let again = LocalStore(directory: directory)
        try await again.load()
        #expect(await again.coins == [coin])
        try await again.setCoins([])
        #expect(await again.coins.isEmpty)
    }

    @Test("Fichiers privés : protection complète ; un fichier illisible n'est jamais remplacé par une liste vide")
    func protectionAndUnreadableFile() async throws {
        #expect(LocalStore.writingOptions.contains(.completeFileProtection))
        #expect(LocalStore.writingOptions.contains(.atomic))

        // illisible (ici un dossier à la place du fichier, comme un fichier protégé appareil verrouillé) :
        // rien n'est chargé, rien n'est écrit
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appending(path: "coins.json", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let store = LocalStore(directory: directory)
        await #expect(throws: (any Error).self) { try await store.load() }
        let coin = Coin(name: "Col", lat: 47.0, lon: 6.0, target: "cepes", altClass: 750, t: ["boletus_edulis": 0.8])
        await #expect(throws: (any Error).self) { try await store.setCoins([coin]) }
        let observation = FieldObservation(species: "boletus_edulis", lat: 47.0, lon: 6.0, date: "2026-11-13", found: false, quantity: nil)
        await #expect(throws: (any Error).self) { try await store.add(observation) }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: blocked.path(percentEncoded: false), isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "observations.json").path(percentEncoded: false)))
        // redevenu lisible : la lecture est retentée d'elle-même
        try FileManager.default.removeItem(at: blocked)
        try await store.setCoins([coin])
        #expect(await store.coins == [coin])

        // lu mais indéchiffrable : l'erreur est dite une fois, puis le magasin repart d'une liste vide
        let other = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: other) }
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("pas du JSON".utf8).write(to: other.appending(path: "coins.json"))
        let corrupt = LocalStore(directory: other)
        await #expect(throws: DecodingError.self) { try await corrupt.load() }
        try await corrupt.load()
        #expect(await corrupt.coins.isEmpty)
        try await corrupt.setCoins([coin])
        let reread = LocalStore(directory: other)
        try await reread.load()
        #expect(await reread.coins == [coin])
    }

    @Test("Forme de l'API : clés snake_case, jeton absent quand nil, réponses décodées")
    func wireFormat() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let observation = FieldObservation(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, species: "boletus_edulis", lat: 47.0, lon: 6.0,
            accuracyM: 12, date: "2026-10-31", found: true, quantity: 2
        )
        let json = String(decoding: try encoder.encode(ObservationsBatch(observations: [observation])), as: UTF8.self)
        #expect(json.contains("\"accuracy_m\":12"))
        #expect(json.contains("\"id\":\"11111111-1111-1111-1111-111111111111\""))
        #expect(json.contains("\"quantity\":2"))
        #expect(json.hasPrefix("{\"observations\":[{"))

        let body = String(decoding: try encoder.encode(CoinsBody(apnsToken: nil, sandbox: true, coins: [
            Coin(name: "Col", lat: 47.0, lon: 6.0, target: "cepes", altClass: 750, t: ["boletus_edulis": 0.8]),
        ])), as: UTF8.self)
        #expect(!body.contains("apns_token"))
        #expect(body.contains("\"alt_class\":750"))
        #expect(body.contains("\"sandbox\":true"))
        #expect(body.contains("\"target\":\"cepes\""))

        let remote = try Fixtures.decode(ObservationsResponse.self, """
        {"count": 1, "observations": [{"id": "22222222-2222-2222-2222-222222222222", "species": "boletus_edulis",
          "lat": 47.0, "lon": 6.0, "accuracy_m": null, "date": "2026-10-30", "found": false, "quantity": null}]}
        """)
        #expect(remote.count == 1 && remote.observations[0].found == false && remote.observations[0].quantity == nil)

        let coins = try Fixtures.decode(CoinsResponse.self, """
        {"today": "2026-10-31", "coins": [{"id": "33333333-3333-3333-3333-333333333333", "user_id": "x", "name": "Col",
          "lat": 47.0, "lon": 6.0, "target": "cepes", "alt_class": 750, "t": {"boletus_edulis": 0.8},
          "score": 0.62, "leading": "boletus_edulis", "best_day": "2026-11-02", "best": 0.7}]}
        """)
        #expect(coins.coins[0].score == 0.62 && coins.coins[0].bestDay == "2026-11-02")
        #expect(coins.coins[0].days.isEmpty)  // serveur d'avant le lot 1 : pas de `days`, pas d'erreur
        let withDays = try Fixtures.decode(CoinsResponse.self, """
        {"today": "2026-10-31", "coins": [{"id": "33333333-3333-3333-3333-333333333333", "name": "Col",
          "lat": 47.0, "lon": 6.0, "target": "cepes", "alt_class": 750, "t": {"boletus_edulis": 0.8},
          "score": 0.62, "leading": "boletus_edulis", "best_day": null, "best": null,
          "days": [{"date": "2026-10-28", "value": 0.5, "leading": "boletus_edulis"}, {"date": "2026-10-29", "value": null, "leading": null}]}]}
        """)
        #expect(withDays.coins[0].days.map(\.date) == ["2026-10-28", "2026-10-29"])
        #expect(withDays.coins[0].days[0].value == 0.5 && withDays.coins[0].days[1].value == nil)
        let post = try Fixtures.decode(ObservationsPostResponse.self, #"{"inserted": 2, "duplicates": 1}"#)
        #expect(post.inserted == 2 && post.duplicates == 1)
        #expect(try Fixtures.decode(DeleteResponse.self, #"{"deleted": 5}"#).deleted == 5)
        #expect(FieldModel.isoDay(Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian).withUTC()) == "1970-01-01")
    }
}

/// Fusion des coins de l'appareil et du serveur (décision du 13 nov. 2026) : fonction pure, à trois
/// listes (appareil, serveur, base du dernier échange réussi).
struct CoinMergeTests {
    static func coin(_ name: String, id: UUID = UUID()) -> Coin {
        Coin(id: id, name: name, lat: 47.0, lon: 6.0, target: "cepes", altClass: 750, t: ["boletus_edulis": 0.8])
    }

    static func renamed(_ coin: Coin, _ name: String) -> Coin {
        var copy = coin
        copy.name = name
        return copy
    }

    @Test("Union par id : chaque appareil garde les coins de l'autre")
    func union() {
        let mine = Self.coin("Col")
        let theirs = Self.coin("Hêtraie")
        // jamais rien échangé (base vide) : tout est gardé, et il faut envoyer
        let first = CoinMerge.merge(local: [mine], remote: [theirs], base: [])
        #expect(first.coins == [mine, theirs])
        #expect(first.needsPush)
        // les deux listes vides, ou identiques : rien à envoyer
        #expect(CoinMerge.merge(local: [], remote: [], base: []) == CoinMerge.Result(coins: [], needsPush: false))
        let settled = CoinMerge.merge(local: [mine, theirs], remote: [theirs, mine], base: [mine, theirs])
        #expect(settled.coins == [mine, theirs])
        #expect(!settled.needsPush)
        // appareil neuf (réinstallation) : il reprend tout du serveur, sans rien renvoyer
        let fresh = CoinMerge.merge(local: [], remote: [mine, theirs], base: [])
        #expect(fresh.coins == [mine, theirs] && !fresh.needsPush)
    }

    @Test("Même id des deux côtés : la version de l'appareil si elle a changé ici, sinon celle du serveur")
    func sameID() {
        let base = Self.coin("Col")
        let here = Self.renamed(base, "Col du Nord")
        let there = Self.renamed(base, "Col (crête)")
        // renommé ici seulement
        let localEdit = CoinMerge.merge(local: [here], remote: [base], base: [base])
        #expect(localEdit.coins == [here] && localEdit.needsPush)
        // renommé ailleurs seulement : l'appareil suit, rien à renvoyer
        let remoteEdit = CoinMerge.merge(local: [base], remote: [there], base: [base])
        #expect(remoteEdit.coins == [there] && !remoteEdit.needsPush)
        // renommé des deux côtés : pas d'horodatage, la version de l'appareil
        let both = CoinMerge.merge(local: [here], remote: [there], base: [base])
        #expect(both.coins == [here] && both.needsPush)
        // sans base (fichier d'avant la fusion) : la version de l'appareil
        let noBase = CoinMerge.merge(local: [here], remote: [there], base: [])
        #expect(noBase.coins == [here] && noBase.needsPush)
    }

    @Test("Suppressions : la base sert de pierre tombale, dans les deux sens")
    func deletions() {
        let kept = Self.coin("Hêtraie")
        let gone = Self.coin("Col")
        // supprimé ici (hors ligne) : le serveur l'a encore, la fusion ne le ressuscite pas
        let deletedHere = CoinMerge.merge(local: [kept], remote: [kept, gone], base: [kept, gone])
        #expect(deletedHere.coins == [kept] && deletedHere.needsPush)
        // supprimé sur un autre appareil : il part d'ici aussi, rien à renvoyer
        let deletedThere = CoinMerge.merge(local: [kept, gone], remote: [kept], base: [kept, gone])
        #expect(deletedThere.coins == [kept] && !deletedThere.needsPush)
        // supprimé ailleurs mais renommé ici entre-temps : la modification de l'appareil n'est pas perdue
        let edited = Self.renamed(gone, "Col du Nord")
        let conflict = CoinMerge.merge(local: [kept, edited], remote: [kept], base: [kept, gone])
        #expect(conflict.coins == [kept, edited] && conflict.needsPush)
        // supprimé des deux côtés
        let both = CoinMerge.merge(local: [kept], remote: [kept], base: [kept, gone])
        #expect(both.coins == [kept] && !both.needsPush)
        // créé hors ligne ici pendant qu'un autre en créait un : les deux restent
        let offline = Self.coin("Sapinière")
        let other = Self.coin("Chênaie")
        let created = CoinMerge.merge(local: [kept, offline], remote: [kept, other], base: [kept])
        #expect(created.coins == [kept, offline, other] && created.needsPush)
    }

    @Test("Comparaison sans ordre ; un id en double ne compte qu'une fois")
    func sameAndDuplicates() {
        let a = Self.coin("A")
        let b = Self.coin("B")
        #expect(CoinMerge.same([a, b], [b, a]))
        #expect(!CoinMerge.same([a], [a, b]))
        #expect(!CoinMerge.same([a], [Self.renamed(a, "A'")]))
        let doubled = CoinMerge.merge(local: [a, a], remote: [b, b], base: [])
        #expect(doubled.coins == [a, b])
    }

    @Test("Magasin : fusion écrite d'un tenant, base gardée par identifiant, relue du disque")
    func storeMerge() async throws {
        let directory = FieldStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UUID()
        let mine = Self.coin("Col")
        let theirs = Self.coin("Hêtraie")
        let store = LocalStore(directory: directory)
        try await store.addCoin(mine)
        #expect(await store.coinsBase(for: user).isEmpty)

        let merged = try await store.mergeCoins(remote: [theirs], for: user)
        #expect(merged.coins == [mine, theirs] && merged.needsPush)
        #expect(await store.coins == [mine, theirs])
        #expect(await store.coinsBase(for: user) == [theirs])  // ce que le serveur a, pas encore « Col »
        try await store.setCoinsBase([mine, theirs], for: user)  // après le PUT

        // suppression et renommage sur l'appareil : la base ne bouge pas
        try await store.removeCoin(theirs.id)
        #expect(try await store.renameCoin(mine.id, to: "Col du Nord"))
        #expect(try await store.renameCoin(UUID(), to: "inconnu") == false)
        let again = LocalStore(directory: directory)
        try await again.load()
        #expect(await again.coins.map(\.name) == ["Col du Nord"])
        #expect(await again.coinsBase(for: user) == [mine, theirs])
        // le serveur a encore les deux : « Hêtraie » supprimé ici n'est pas repris
        let next = try await again.mergeCoins(remote: [mine, theirs], for: user)
        #expect(next.coins.map(\.name) == ["Col du Nord"] && next.needsPush)

        // un fichier d'avant la fusion (sans base) se relit
        let legacy = try JSONDecoder().decode(LocalStore.CoinsFile.self, from: Data(#"{"version": 1, "coins": []}"#.utf8))
        #expect(legacy.synced == nil && legacy.syncedFor == nil)
    }

    @Test("Identifiant de l'app changé : la base de l'ancien ne vaut plus, les coins repartent sous de nouveaux id")
    func identityChanged() async throws {
        let directory = FieldStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = UUID()
        let after = UUID()
        let mine = Self.coin("Col")
        let theirs = Self.coin("Hêtraie")
        let store = LocalStore(directory: directory)
        try await store.addCoin(mine)
        _ = try await store.mergeCoins(remote: [], for: before)
        try await store.setCoinsBase([mine], for: before)
        #expect(await store.coinsBase(for: after).isEmpty)

        // sous le nouvel identifiant, le serveur n'a que le coin de l'autre appareil : « Col » n'est
        // pas pris pour une suppression faite ailleurs, il est gardé sous un nouvel id
        let merged = try await store.mergeCoins(remote: [theirs], for: after)
        #expect(merged.coins.map(\.name) == ["Col", "Hêtraie"] && merged.needsPush)
        #expect(merged.coins[0].id != mine.id)
        #expect(merged.coins[0].lat == mine.lat && merged.coins[0].t == mine.t && merged.coins[0].altClass == mine.altClass)
        #expect(await store.coinsBase(for: after) == [theirs])
        #expect(await store.coinsBase(for: before).isEmpty)
    }
}

/// Trousseau factice : absent, présent, en erreur, ou qui reçoit un identifiant d'un autre appareil
/// pendant qu'on écrit le nôtre.
nonisolated final class ScriptedIdentityStore: IdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UUID?
    private var loadError: IdentityError?
    private var saveError: IdentityError?
    /// Identifiant qu'un autre appareil écrit juste avant notre ajout (doublon).
    private var racing: UUID?
    private var saves: [UUID] = []

    init(_ id: UUID? = nil) {
        stored = id
    }

    func set(stored: UUID?? = nil, loadError: IdentityError?? = nil, saveError: IdentityError?? = nil, racing: UUID?? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let stored { self.stored = stored }
        if let loadError { self.loadError = loadError }
        if let saveError { self.saveError = saveError }
        if let racing { self.racing = racing }
    }

    var saved: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return saves
    }

    var current: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func load() throws -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        if let loadError { throw loadError }
        return stored
    }

    func save(_ id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        if let saveError { throw saveError }
        if let racing {
            stored = racing
            self.racing = nil
        }
        guard stored == nil else { throw IdentityError.duplicate }
        stored = id
        saves.append(id)
    }
}

struct IdentityTests {
    /// `errSecInteractionNotAllowed` : trousseau verrouillé avant le premier déverrouillage.
    static let locked = IdentityError.keychain(-25308)

    @Test("Absent du trousseau : créé une fois, relu ensuite, retenu comme dernier connu")
    func createdOnce() throws {
        let store = ScriptedIdentityStore()
        let memory = VolatileIdentityMemory()
        let provider = IdentityProvider(store: store, memory: memory)
        let first = try Identity.resolve(provider)
        #expect(store.current == first)
        #expect(store.saved == [first])
        #expect(try Identity.resolve(provider) == first)
        #expect(store.saved == [first])  // pas de seconde écriture
        #expect(memory.lastKnown() == first)
        #expect(memory.retired().isEmpty)
    }

    @Test("Erreur du trousseau : remontée, jamais de nouvel identifiant")
    func keychainErrorIsNotAbsence() throws {
        let store = ScriptedIdentityStore()
        store.set(loadError: Self.locked)
        let memory = VolatileIdentityMemory()
        let provider = IdentityProvider(store: store, memory: memory)
        #expect(throws: Self.locked) { try Identity.resolve(provider) }
        #expect(store.saved.isEmpty)
        #expect(memory.lastKnown() == nil)

        // l'écriture échoue (trousseau refusé) : remontée aussi, rien n'est retenu
        store.set(loadError: .some(nil), saveError: IdentityError.keychain(-34018))
        #expect(throws: IdentityError.keychain(-34018)) { try Identity.resolve(provider) }
        #expect(memory.lastKnown() == nil)

        // le trousseau répond de nouveau : l'identifiant est créé
        store.set(saveError: .some(nil))
        let id = try Identity.resolve(provider)
        #expect(store.current == id && memory.lastKnown() == id)
    }

    @Test("Erreur du trousseau avec un identifiant déjà connu : il sert, rien n'est créé ni écrit")
    func knownIdentitySurvivesKeychainError() throws {
        let known = UUID()
        let store = ScriptedIdentityStore(known)
        let memory = VolatileIdentityMemory()
        let provider = IdentityProvider(store: store, memory: memory)
        #expect(try Identity.resolve(provider) == known)
        store.set(loadError: Self.locked)
        #expect(try Identity.resolve(provider) == known)
        #expect(store.saved.isEmpty)
        #expect(memory.retired().isEmpty)
    }

    @Test("Trousseau vidé : le dernier identifiant connu y est remis, pas un nouveau")
    func lastKnownIsRestored() throws {
        let known = UUID()
        let store = ScriptedIdentityStore()
        let memory = VolatileIdentityMemory(lastKnown: known)
        #expect(try Identity.resolve(IdentityProvider(store: store, memory: memory)) == known)
        #expect(store.current == known)
        #expect(memory.retired().isEmpty)
    }

    @Test("Doublon à l'écriture : l'identifiant du trousseau fait foi, il n'est pas écrasé")
    func duplicateIsNeverOverwritten() throws {
        let other = UUID()
        let store = ScriptedIdentityStore()
        store.set(racing: other)
        let memory = VolatileIdentityMemory()
        let id = try Identity.resolve(IdentityProvider(store: store, memory: memory))
        #expect(id == other)
        #expect(store.current == other)
        #expect(store.saved.isEmpty)
        #expect(memory.lastKnown() == other)
        // le magasin de mémoire refuse lui aussi d'écraser
        let plain = MemoryIdentityStore(other)
        #expect(throws: IdentityError.duplicate) { try plain.save(UUID()) }
        #expect(try plain.load() == other)
    }

    @Test("Conflit iCloud : l'identifiant lu change, l'ancien est mis de côté pour l'effacement")
    func conflictKeepsTheOldAside() throws {
        let mine = UUID()
        let theirs = UUID()
        let store = ScriptedIdentityStore(mine)
        let memory = VolatileIdentityMemory()
        let provider = IdentityProvider(store: store, memory: memory)
        #expect(try Identity.resolve(provider) == mine)
        // iCloud réunit les deux appareils : celui de l'autre l'emporte
        store.set(stored: theirs)
        #expect(try Identity.resolve(provider) == theirs)
        #expect(memory.lastKnown() == theirs)
        #expect(memory.retired() == [mine])
        // relu sans changement : rien de plus de côté
        #expect(try Identity.resolve(provider) == theirs)
        #expect(memory.retired() == [mine])
        // il revient : il n'est plus de côté, l'autre l'est
        store.set(stored: mine)
        #expect(try Identity.resolve(provider) == mine)
        #expect(memory.retired() == [theirs])
    }
}

@MainActor
struct IdentityFieldTests {
    @Test("Trousseau en erreur : dit en clair, rien n'est envoyé ; « Réessayer » reprend")
    func visibleStateAndRetry() async throws {
        let directory = FieldStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = StubURLProtocol.host()
        StubURLProtocol.set(host: host) { method, path, _ in
            (method, path) == ("POST", "/observations") ? (201, #"{"inserted": 1, "duplicates": 0}"#) : (404, #"{"detail": "inconnu"}"#)
        }
        let store = ScriptedIdentityStore()
        store.set(loadError: IdentityTests.locked)
        let model = FieldModel(
            api: StubURLProtocol.api(host: host), store: LocalStore(directory: directory),
            identity: IdentityProvider(store: store, memory: VolatileIdentityMemory())
        )
        model.asksNotificationPermission = false
        await model.start(api: model.api)
        #expect(model.userID == nil)
        let problem = try #require(model.problem)
        #expect(problem.text == "L'identifiant de l'app n'a pas pu être lu : observations et coins restent sur l'appareil")
        #expect(problem.retryable)

        // l'observation est gardée sur l'appareil, rien ne part sans identifiant
        await model.record(species: "boletus_edulis", latitude: 47.0, longitude: 6.0, accuracyM: nil, date: "2026-11-13", found: true, quantity: 1)
        #expect(model.observations.count == 1 && model.pendingCount == 1)
        #expect(StubURLProtocol.requests(host: host).isEmpty)
        #expect(store.saved.isEmpty)

        // le trousseau répond : « Réessayer » lit l'identifiant et envoie ce qui attendait
        let id = UUID()
        store.set(stored: id, loadError: .some(nil))
        await model.retry()
        #expect(model.userID == id)
        #expect(model.problem == nil)
        #expect(model.pendingCount == 0)
        #expect(StubURLProtocol.requests(host: host).first { $0.method == "POST" }?.user == id.uuidString.lowercased())
    }

    @Test("Tout supprimer : l'identifiant mis de côté est effacé du serveur lui aussi, puis oublié")
    func deleteAllErasesRetiredIdentities() async throws {
        let directory = FieldStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = StubURLProtocol.host()
        StubURLProtocol.set(host: host) { method, path, _ in
            (method, path) == ("DELETE", "/observations") ? (200, #"{"deleted": 1}"#) : (404, #"{"detail": "inconnu"}"#)
        }
        let old = UUID()
        let current = UUID()
        let memory = VolatileIdentityMemory(lastKnown: old)
        let model = FieldModel(
            api: StubURLProtocol.api(host: host), store: LocalStore(directory: directory),
            identity: IdentityProvider(store: ScriptedIdentityStore(current), memory: memory)
        )
        model.asksNotificationPermission = false
        await model.start(api: model.api)
        #expect(model.userID == current)
        #expect(memory.retired() == [old])

        await model.deleteAll()
        let deletes = StubURLProtocol.requests(host: host).filter { $0.method == "DELETE" }
        #expect(deletes.map(\.user) == [old.uuidString.lowercased(), current.uuidString.lowercased()])
        #expect(memory.retired().isEmpty)
        #expect(model.status == "Observations et coins effacés")
        #expect(model.userID == current)  // l'identifiant de l'app reste le sien
    }
}

extension Calendar {
    func withUTC() -> Calendar {
        var calendar = self
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}
