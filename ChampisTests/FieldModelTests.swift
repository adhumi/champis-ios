import Foundation
import Testing
@testable import Champis

/// Serveur champis-api factice. Les tests tournent en parallèle : chaque test prend son propre hôte
/// (`StubURLProtocol.host()`), et gestionnaires comme requêtes sont rangés par hôte.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (String, String, Data?) -> (Int, String)
    typealias Binary = @Sendable (String, String) -> Data?
    typealias Request = (method: String, path: String, user: String?, body: Data?, query: String?)

    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var binaries: [String: Binary] = [:]
    nonisolated(unsafe) private static var log: [String: [Request]] = [:]
    private static let lock = NSLock()

    /// Un hôte unique pour un test.
    static func host() -> String {
        "t" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12) + ".test"
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    static func api(host: String) -> ChampisAPI {
        ChampisAPI(baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration()))
    }

    static func set(host: String, binary: Binary? = nil, handler: Handler?) {
        lock.lock()
        defer { lock.unlock() }
        handlers[host] = handler
        binaries[host] = binary
        log[host] = log[host] ?? []
    }

    static func requests(host: String) -> [Request] {
        lock.lock()
        defer { lock.unlock() }
        return log[host] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        Self.lock.lock()
        Self.log[host, default: []].append((method, path, request.value(forHTTPHeaderField: "X-Champis-User"), body, request.url?.query))
        let handler = Self.handlers[host]
        let binary = Self.binaries[host]
        Self.lock.unlock()

        let status: Int
        let payload: Data
        let contentType: String
        if let data = binary?(method, path) {
            (status, payload, contentType) = (200, data, "application/octet-stream")
        } else {
            let (code, json) = handler?(method, path, body) ?? (404, #"{"detail": "inconnu"}"#)
            (status, payload, contentType) = (code, Data(json.utf8), "application/json")
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
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
    static func model(host: String, directory: URL) -> FieldModel {
        let model = FieldModel(
            api: StubURLProtocol.api(host: host), store: LocalStore(directory: directory),
            identityStores: [MemoryIdentityStore()]
        )
        model.asksNotificationPermission = false
        return model
    }

    @Test("Observation : enregistrée localement, envoyée avec l'identifiant, en attente si le serveur tombe")
    func recordAndSync() async throws {
        let directory = FieldStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = StubURLProtocol.host()
        StubURLProtocol.set(host: host) { method, path, _ in
            (method, path) == ("POST", "/observations") ? (201, #"{"inserted": 1, "duplicates": 0}"#) : (404, #"{"detail": "inconnu"}"#)
        }
        let model = Self.model(host: host, directory: directory)
        await model.start(api: model.api)
        let user = try #require(model.userID)

        await model.record(species: "boletus_edulis", latitude: 47.0, longitude: 6.0, accuracyM: 12, date: "2026-10-31", found: true, quantity: 2)
        #expect(model.observations.count == 1)
        #expect(model.pendingCount == 0)
        #expect(model.problem == nil)
        let post = try #require(StubURLProtocol.requests(host: host).first { $0.method == "POST" })
        #expect(post.path == "/observations")
        #expect(post.user == user.uuidString.lowercased())
        let sent = StubURLProtocol.json(post.body)["observations"] as? [[String: Any]]
        #expect(sent?.count == 1)
        #expect(sent?[0]["species"] as? String == "boletus_edulis")
        #expect(sent?[0]["accuracy_m"] as? Double == 12)
        #expect(sent?[0]["quantity"] as? Int == 2)

        // serveur indisponible : l'observation reste en attente, le message le dit en clair (étape B4)
        StubURLProtocol.set(host: host) { _, _, _ in (503, #"{"detail": "observations non configurées"}"#) }
        await model.record(species: "boletus_aereus", latitude: 47.0, longitude: 6.0, accuracyM: nil, date: "2026-10-31", found: false, quantity: nil)
        #expect(model.observations.count == 2)
        #expect(model.pendingCount == 1)
        let problem = try #require(model.problem)
        #expect(problem.text == "Observations pas encore envoyées, elles restent sur l'appareil : le serveur est momentanément indisponible")
        #expect(problem.detail == "HTTP 503 : observations non configurées")
        #expect(problem.retryable)

        // retour du réseau : « Réessayer » relance l'envoi
        StubURLProtocol.set(host: host) { method, path, _ in
            (method, path) == ("POST", "/observations") ? (201, #"{"inserted": 1, "duplicates": 0}"#) : (404, "{}")
        }
        await model.retry()
        #expect(model.pendingCount == 0)
        #expect(model.problem == nil)
    }

    @Test("Rien trouvé en une tape : une négative par espèce, retenue pendant le délai, annulable, puis envoyée")
    func notFoundUndo() async throws {
        let directory = FieldStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = StubURLProtocol.host()
        StubURLProtocol.set(host: host) { method, path, _ in
            (method, path) == ("POST", "/observations") ? (201, #"{"inserted": 2, "duplicates": 0}"#) : (404, "{}")
        }
        let model = Self.model(host: host, directory: directory)
        model.undoWindow = .milliseconds(150)
        await model.start(api: model.api)

        // annulé avant la fin du délai : rien n'est envoyé, rien ne reste
        await model.recordNotFound(species: ["boletus_aereus", "boletus_edulis"], latitude: 47, longitude: 6)
        #expect(model.observations.count == 2)
        #expect(model.observations.allSatisfy { !$0.found && $0.quantity == nil && $0.date == FieldModel.isoDay() })
        #expect(model.undoable.count == 2)
        #expect(model.pendingCount == 2)
        await model.sync()  // un envoi explicite respecte aussi le délai
        #expect(StubURLProtocol.requests(host: host).filter { $0.method == "POST" }.isEmpty)
        await model.undoNotFound()
        #expect(model.observations.isEmpty)
        #expect(model.undoable.isEmpty)
        #expect(model.pendingCount == 0)

        // laissé passer : envoyé à la fin du délai, avec la précision GPS de « Noter » (étape B4)
        await model.recordNotFound(species: ["boletus_edulis"], latitude: 47, longitude: 6, accuracyM: 8)
        #expect(model.undoable.count == 1)
        try await Task.sleep(for: .milliseconds(600))
        #expect(model.undoable.isEmpty)
        #expect(model.pendingCount == 0)
        let post = try #require(StubURLProtocol.requests(host: host).first { $0.method == "POST" })
        let sent = StubURLProtocol.json(post.body)["observations"] as? [[String: Any]]
        #expect(sent?.count == 1)
        #expect(sent?[0]["found"] as? Bool == false)
        #expect(sent?[0]["accuracy_m"] as? Double == 8)

        // aucune espèce : rien de noté, rien à annuler
        await model.recordNotFound(species: [], latitude: 47, longitude: 6)
        #expect(model.undoable.isEmpty)
        #expect(model.observations.count == 1)
    }

    @Test("Coins : PUT en liste complète sans jeton, scores relus ; suppression totale")
    func coinsAndDelete() async throws {
        let directory = FieldStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = StubURLProtocol.host()
        StubURLProtocol.set(host: host) { method, path, _ in
            switch (method, path) {
            case ("PUT", "/coins"):
                return (200, #"{"coins": 1, "notifications": false}"#)
            case ("GET", "/coins"):
                let last = StubURLProtocol.requests(host: host).last { $0.method == "PUT" }
                let coins = StubURLProtocol.json(last?.body)["coins"] as? [[String: Any]] ?? []
                let id = coins.first?["id"] as? String ?? UUID().uuidString
                return (200, """
                {"today": "2026-10-31", "coins": [{"id": "\(id)", "name": "Col", "lat": 47.0, "lon": 6.0, "target": "cepes",
                  "alt_class": 750, "t": {"boletus_edulis": 0.8}, "score": 0.7, "leading": "boletus_edulis",
                  "best_day": null, "best": null,
                  "summary": ["grosse pluie il y a 8 jours : en plein dans le délai de pousse", "pleine saison"],
                  "days": [{"date": "2026-10-31", "value": 0.7, "leading": "boletus_edulis"},
                           {"date": "2026-11-01", "value": null, "leading": null}]}]}
                """)
            case ("DELETE", "/observations"):
                return (200, #"{"deleted": 1}"#)
            default:
                return (404, #"{"detail": "inconnu"}"#)
            }
        }
        let model = Self.model(host: host, directory: directory)
        await model.start(api: model.api)

        await model.addCoin(name: "Col", latitude: 47.0, longitude: 6.0, target: "cepes", altClass: 750, t: ["boletus_edulis": 0.8])
        #expect(model.coins.count == 1)
        let put = try #require(StubURLProtocol.requests(host: host).first { $0.method == "PUT" })
        let body = StubURLProtocol.json(put.body)
        #expect(body["apns_token"] == nil)
        #expect(body["sandbox"] as? Bool == FieldModel.isSandboxBuild)
        let coins = body["coins"] as? [[String: Any]]
        #expect(coins?.count == 1)
        #expect(coins?[0]["alt_class"] as? Int == 750)
        #expect(coins?[0]["target"] as? String == "cepes")
        let coin = try #require(model.coins.first)
        #expect(model.coinScores[coin.id]?.score == 0.7, "\(model.problem?.detail ?? "")")
        #expect(model.coinsToday == "2026-10-31")
        // phrases du jour du coin (étape B2)
        #expect(model.coinScores[coin.id]?.summary == ["grosse pluie il y a 8 jours : en plein dans le délai de pousse", "pleine saison"])
        #expect(model.coinScores[coin.id]?.days.count == 2)
        #expect(model.coinScores[coin.id]?.days.last?.value == nil)

        await model.renameCoin(coin.id, to: "  Col du Nord ")
        #expect(model.coins.first?.name == "Col du Nord")
        #expect(StubURLProtocol.requests(host: host).filter { $0.method == "PUT" }.count == 2)
        await model.renameCoin(coin.id, to: "   ")  // vide : ignoré, pas d'appel
        #expect(model.coins.first?.name == "Col du Nord")
        #expect(StubURLProtocol.requests(host: host).filter { $0.method == "PUT" }.count == 2)

        await model.removeCoin(coin.id)
        #expect(model.coins.isEmpty)
        #expect(StubURLProtocol.requests(host: host).filter { $0.method == "PUT" }.count == 3)

        await model.addCoin(name: "Autre", latitude: 47.0, longitude: 6.0, target: "cepes", altClass: 450, t: ["boletus_edulis": 0.5])
        await model.deleteAll()
        #expect(StubURLProtocol.requests(host: host).contains { $0.method == "DELETE" && $0.path == "/observations" })
        #expect(model.coins.isEmpty, "\(model.problem?.detail ?? "")")
        #expect(model.status == "Observations et coins effacés")
        #expect(model.observations.isEmpty)
        #expect(model.coinScores.isEmpty)
    }
}
