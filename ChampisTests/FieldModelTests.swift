import Foundation
import Testing
@testable import Champis

/// Serveur champis-api factice : enregistre les requêtes (méthode, chemin, en-tête d'identité, corps)
/// et répond selon un gestionnaire remplaçable par le test.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (String, String, Data?) -> (Int, String))?
    nonisolated(unsafe) static var requests: [(method: String, path: String, user: String?, body: Data?)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        StubURLProtocol.requests.append((method, path, request.value(forHTTPHeaderField: "X-Champis-User"), body))
        let (status, json) = StubURLProtocol.handler?(method, path, body) ?? (404, #"{"detail": "inconnu"}"#)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    static func json(_ body: Data?) -> [String: Any] {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
        return object
    }
}

@MainActor
struct FieldModelTests {
    static func model(directory: URL) -> FieldModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = ChampisAPI(baseURL: URL(string: "https://api.test")!, session: URLSession(configuration: configuration))
        let model = FieldModel(api: api, store: LocalStore(directory: directory), identityStores: [MemoryIdentityStore()])
        model.asksNotificationPermission = false
        return model
    }

    @Test("FieldObservation : enregistrée localement, envoyée avec l'identifiant, en attente si le serveur tombe")
    func recordAndSync() async throws {
        let directory = FieldStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        StubURLProtocol.requests = []
        StubURLProtocol.handler = { method, path, _ in
            switch (method, path) {
            case ("POST", "/observations"): (201, #"{"inserted": 1, "duplicates": 0}"#)
            default: (404, #"{"detail": "inconnu"}"#)
            }
        }
        let model = Self.model(directory: directory)
        await model.start(api: model.api)
        let user = try #require(model.userID)

        await model.record(species: "boletus_edulis", latitude: 47.0, longitude: 6.0, accuracyM: 12, date: "2026-10-31", found: true, quantity: 2)
        #expect(model.observations.count == 1)
        #expect(model.pendingCount == 0)
        #expect(model.status == nil)
        let post = try #require(StubURLProtocol.requests.first { $0.method == "POST" })
        #expect(post.path == "/observations")
        #expect(post.user == user.uuidString.lowercased())
        let sent = StubURLProtocol.json(post.body)["observations"] as? [[String: Any]]
        #expect(sent?.count == 1)
        #expect(sent?[0]["species"] as? String == "boletus_edulis")
        #expect(sent?[0]["accuracy_m"] as? Double == 12)
        #expect(sent?[0]["quantity"] as? Int == 2)

        // serveur indisponible : l'observation reste en attente, le statut le dit
        StubURLProtocol.handler = { _, _, _ in (503, #"{"detail": "observations non configurées"}"#) }
        await model.record(species: "boletus_aereus", latitude: 47.0, longitude: 6.0, accuracyM: nil, date: "2026-10-31", found: false, quantity: nil)
        #expect(model.observations.count == 2)
        #expect(model.pendingCount == 1)
        #expect(model.status?.contains("non configurées") == true)

        // retour du réseau : l'envoi reprend
        StubURLProtocol.handler = { method, path, _ in
            (method, path) == ("POST", "/observations") ? (201, #"{"inserted": 1, "duplicates": 0}"#) : (404, "{}")
        }
        await model.sync()
        #expect(model.pendingCount == 0)
        #expect(model.status == nil)
    }

    @Test("Coins : PUT en liste complète sans jeton, scores relus ; suppression totale")
    func coinsAndDelete() async throws {
        let directory = FieldStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        StubURLProtocol.requests = []
        StubURLProtocol.handler = { method, path, body in
            switch (method, path) {
            case ("PUT", "/coins"):
                return (200, #"{"coins": 1, "notifications": false}"#)
            case ("GET", "/coins"):
                let last = StubURLProtocol.requests.last { $0.method == "PUT" }
                let coins = StubURLProtocol.json(last?.body)["coins"] as? [[String: Any]] ?? []
                let id = coins.first?["id"] as? String ?? UUID().uuidString
                return (200, """
                {"today": "2026-10-31", "coins": [{"id": "\(id)", "name": "Col", "lat": 47.0, "lon": 6.0, "target": "cepes",
                  "alt_class": 750, "t": {"boletus_edulis": 0.8}, "score": 0.7, "leading": "boletus_edulis",
                  "best_day": null, "best": null}]}
                """)
            case ("DELETE", "/observations"):
                return (200, #"{"deleted": 1}"#)
            default:
                _ = body
                return (404, #"{"detail": "inconnu"}"#)
            }
        }
        let model = Self.model(directory: directory)
        await model.start(api: model.api)

        await model.addCoin(name: "Col", latitude: 47.0, longitude: 6.0, target: "cepes", altClass: 750, t: ["boletus_edulis": 0.8])
        #expect(model.coins.count == 1)
        let put = try #require(StubURLProtocol.requests.first { $0.method == "PUT" })
        let body = StubURLProtocol.json(put.body)
        #expect(body["apns_token"] == nil)
        #expect(body["sandbox"] as? Bool == FieldModel.isSandboxBuild)
        let coins = body["coins"] as? [[String: Any]]
        #expect(coins?.count == 1)
        #expect(coins?[0]["alt_class"] as? Int == 750)
        #expect(coins?[0]["target"] as? String == "cepes")
        let coin = try #require(model.coins.first)
        #expect(model.coinScores[coin.id]?.score == 0.7)
        #expect(model.coinsToday == "2026-10-31")

        await model.removeCoin(coin.id)
        #expect(model.coins.isEmpty)
        #expect(StubURLProtocol.requests.filter { $0.method == "PUT" }.count == 2)

        await model.addCoin(name: "Autre", latitude: 47.0, longitude: 6.0, target: "cepes", altClass: 450, t: ["boletus_edulis": 0.5])
        await model.deleteAll()
        #expect(StubURLProtocol.requests.contains { $0.method == "DELETE" && $0.path == "/observations" })
        #expect(model.coins.isEmpty)
        #expect(model.observations.isEmpty)
        #expect(model.coinScores.isEmpty)
    }
}
