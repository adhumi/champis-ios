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

        let older = Observation(species: "boletus_edulis", lat: 47.0, lon: 6.0, date: "2026-10-29", found: false, quantity: 2)
        let newer = Observation(species: "boletus_edulis", lat: 47.1, lon: 6.1, accuracyM: 8, date: "2026-10-31", found: true, quantity: 3)
        try await store.add(older)
        try await store.add(newer)
        #expect(older.quantity == nil)  // rien trouvé : la quantité n'a pas de sens
        #expect(await store.observations.map(\.date) == ["2026-10-31", "2026-10-29"])
        #expect(await store.pendingCount == 2)

        try await store.markSynced([older.id])
        #expect(await store.pendingCount == 1)
        #expect(await store.pendingObservations.map(\.id) == [newer.id])

        // le serveur connaît l'ancienne (avec une autre précision) et une inconnue ; la locale en attente reste
        var remoteOlder = older
        remoteOlder.accuracyM = 25
        let remoteOther = Observation(species: "boletus_aereus", lat: 46.0, lon: 5.0, date: "2026-10-20", found: true, quantity: 1)
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

    @Test("Forme de l'API : clés snake_case, jeton absent quand nil, réponses décodées")
    func wireFormat() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let observation = Observation(
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
        let post = try Fixtures.decode(ObservationsPostResponse.self, #"{"inserted": 2, "duplicates": 1}"#)
        #expect(post.inserted == 2 && post.duplicates == 1)
        #expect(try Fixtures.decode(DeleteResponse.self, #"{"deleted": 5}"#).deleted == 5)
        #expect(FieldModel.isoDay(Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian).withUTC()) == "1970-01-01")
    }

    @Test("Identité : créée une fois, relue ensuite, repli sur le magasin suivant")
    func identity() throws {
        let memory = MemoryIdentityStore()
        let first = Identity.userID(from: [memory])
        #expect(first != nil)
        #expect(Identity.userID(from: [memory]) == first)
        #expect(try memory.load() == first)

        let failing = FailingIdentityStore()
        let fallback = MemoryIdentityStore()
        let id = Identity.userID(from: [failing, fallback])
        #expect(id != nil)
        #expect(try fallback.load() == id)
        #expect(Identity.userID(from: [failing]) == nil)
    }
}

nonisolated struct FailingIdentityStore: IdentityStore {
    func load() throws -> UUID? { throw IdentityError.keychain(-1) }
    func save(_ id: UUID) throws { throw IdentityError.keychain(-1) }
}

extension Calendar {
    func withUTC() -> Calendar {
        var calendar = self
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}
