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

    /// Client du serveur factice. `trusted` : l'hôte du test tient lieu d'API officielle (il reçoit
    /// l'identifiant et les données privées) ; faux, c'est une adresse réglée à la main.
    static func api(host: String, trusted: Bool = true) -> ChampisAPI {
        ChampisAPI(
            baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration()),
            trustedHost: trusted ? host : ChampisAPI.officialHost
        )
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

/// Coins et observations d'un serveur champis-api factice, avec la règle du vrai : `PUT /coins`
/// remplace la liste, `GET /coins` la rend avec un score, `DELETE /observations` efface tout.
final class FakeFieldServer: @unchecked Sendable {
    private let lock = NSLock()
    private var coins: [[String: Any]] = []
    private var observations: [[String: Any]] = []
    /// Code HTTP à répondre à tout (panne du serveur), ou `nil`.
    private var failure: Int?

    init(coins: [Coin] = []) {
        self.coins = coins.map(Self.object)
    }

    static func object(_ coin: Coin) -> [String: Any] {
        [
            "id": coin.id.uuidString.lowercased(), "name": coin.name, "lat": coin.lat, "lon": coin.lon,
            "target": coin.target, "alt_class": coin.altClass, "t": coin.t,
        ]
    }

    /// Ce qu'un autre appareil a fait de la liste entre-temps.
    func set(coins: [Coin]) {
        lock.lock()
        defer { lock.unlock() }
        self.coins = coins.map(Self.object)
    }

    func fail(_ status: Int?) {
        lock.lock()
        defer { lock.unlock() }
        failure = status
    }

    var coinNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return coins.compactMap { $0["name"] as? String }.sorted()
    }

    var coinIDs: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(coins.compactMap { $0["id"] as? String })
    }

    func handle(_ method: String, _ path: String, _ body: Data?) -> (Int, String) {
        lock.lock()
        defer { lock.unlock() }
        if let failure {
            return (failure, #"{"detail": "indisponible"}"#)
        }
        switch (method, path) {
        case ("PUT", "/coins"):
            coins = StubURLProtocol.json(body)["coins"] as? [[String: Any]] ?? []
            return (200, #"{"coins": \#(coins.count), "notifications": false}"#)
        case ("GET", "/coins"):
            let summary: [String] = ["pleine saison"]
            let scored = coins.map { coin -> [String: Any] in
                var out = coin
                out["score"] = 0.7
                out["leading"] = "boletus_edulis"
                out["best_day"] = NSNull()
                out["best"] = NSNull()
                out["summary"] = summary
                let days: [[String: Any]] = [
                    ["date": "2026-10-31", "value": 0.7, "leading": "boletus_edulis"],
                    ["date": "2026-11-01", "value": NSNull(), "leading": NSNull()],
                ]
                out["days"] = days
                return out
            }
            return (200, Self.text(["today": "2026-10-31", "coins": scored]))
        case ("GET", "/observations"):
            return (200, Self.text(["count": observations.count, "observations": observations]))
        case ("POST", "/observations"):
            let sent = StubURLProtocol.json(body)["observations"] as? [[String: Any]] ?? []
            observations += sent
            return (201, #"{"inserted": \#(sent.count), "duplicates": 0}"#)
        case ("DELETE", "/observations"):
            let deleted = observations.count
            observations = []
            coins = []
            return (200, #"{"deleted": \#(deleted)}"#)
        default:
            return (404, #"{"detail": "inconnu"}"#)
        }
    }

    static func text(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
struct FieldModelTests {
    static func model(host: String, directory: URL, trusted: Bool = true, identity: IdentityProvider = .inMemory()) -> FieldModel {
        let model = FieldModel(
            api: StubURLProtocol.api(host: host, trusted: trusted), store: LocalStore(directory: directory),
            identity: identity
        )
        model.asksNotificationPermission = false
        return model
    }

    /// Un serveur factice branché sur un hôte de test.
    static func server(coins: [Coin] = []) -> (FakeFieldServer, host: String) {
        let server = FakeFieldServer(coins: coins)
        let host = StubURLProtocol.host()
        StubURLProtocol.set(host: host) { method, path, body in server.handle(method, path, body) }
        return (server, host)
    }

    static func coin(_ name: String) -> Coin {
        Coin(name: name, lat: 47.0, lon: 6.0, target: "cepes", altClass: 750, t: ["boletus_edulis": 0.8])
    }

    static func methods(_ host: String) -> [String] {
        StubURLProtocol.requests(host: host).map { "\($0.method) \($0.path)" }
    }

    // MARK: Fusion des coins au démarrage (13 nov. 2026)

    @Test("Démarrage : les coins du serveur sont lus et fusionnés avant tout PUT ; rien n'est perdu entre deux appareils")
    func mergeBeforeAnyPut() async throws {
        let directory = FieldStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // l'autre appareil a créé « Hêtraie » ; celui-ci a créé « Col » hors ligne, jamais envoyé
        let theirs = Self.coin("Hêtraie")
        let mine = Self.coin("Col")
        let (server, host) = Self.server(coins: [theirs])
        try await LocalStore(directory: directory).setCoins([mine])

        let model = Self.model(host: host, directory: directory)
        await model.start(api: model.api)
        #expect(model.remoteMerged)
        #expect(Set(model.coins.map(\.id)) == [mine.id, theirs.id])
        #expect(model.problem == nil, "\(model.problem?.detail ?? "")")
        // lecture d'abord, PUT ensuite, avec les deux coins
        let methods = Self.methods(host)
        let firstPut = try #require(methods.firstIndex(of: "PUT /coins"))
        let readCoins = try #require(methods.firstIndex(of: "GET /coins"))
        let readObservations = try #require(methods.firstIndex(of: "GET /observations"))
        #expect(readCoins < firstPut && readObservations < firstPut)
        #expect(server.coinNames == ["Col", "Hêtraie"])
        #expect(model.coinScores[theirs.id]?.score == 0.7)
        #expect(model.coinScores[mine.id]?.score == 0.7)

        // au lancement suivant, rien n'a changé : lecture seule, aucun PUT
        let puts = methods.filter { $0 == "PUT /coins" }.count
        let again = Self.model(host: host, directory: directory, identity: IdentityProvider(store: MemoryIdentityStore(model.userID), memory: VolatileIdentityMemory()))
        await again.start(api: again.api)
        #expect(Set(again.coins.map(\.id)) == [mine.id, theirs.id])
        #expect(Self.methods(host).filter { $0 == "PUT /coins" }.count == puts)
    }

    @Test("Aucun PUT tant que la première lecture du serveur n'a pas réussi ; les ajouts attendent sur l'appareil")
    func noPutBeforeFirstRead() async throws {
        let directory = FieldStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let theirs = Self.coin("Hêtraie")
        let (server, host) = Self.server(coins: [theirs])
        server.fail(503)

        let model = Self.model(host: host, directory: directory)
        await model.start(api: model.api)
        #expect(!model.remoteMerged)
        #expect(model.problem == nil)  // rien à envoyer : l'app ne dit rien

        await model.addCoin(name: "Col", latitude: 47.0, longitude: 6.0, target: "cepes", altClass: 750, t: ["boletus_edulis": 0.8])
        #expect(model.coins.map(\.name) == ["Col"])
        #expect(!Self.methods(host).contains("PUT /coins"))
        #expect(server.coinNames == ["Hêtraie"])  // la liste du serveur n'a pas été remplacée
        let problem = try #require(model.problem)
        #expect(problem.text == "Coins pas encore envoyés au serveur : pas de notification d'ici là : le serveur est momentanément indisponible")
        #expect(problem.retryable)

        // le serveur revient : « Réessayer » lit, fusionne, puis envoie
        server.fail(nil)
        await model.retry()
        #expect(model.remoteMerged)
        #expect(model.problem == nil)
        #expect(model.coins.map(\.name).sorted() == ["Col", "Hêtraie"])
        #expect(server.coinNames == ["Col", "Hêtraie"])
    }

    @Test("Un coin supprimé hors ligne n'est pas ressuscité par la fusion")
    func offlineDeletionIsNotResurrected() async throws {
        let directory = FieldStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (server, host) = Self.server()
        let identity = IdentityProvider.inMemory()
        let model = Self.model(host: host, directory: directory, identity: identity)
        await model.start(api: model.api)
        await model.addCoin(name: "Col", latitude: 47.0, longitude: 6.0, target: "cepes", altClass: 750, t: ["boletus_edulis": 0.8])
        await model.addCoin(name: "Hêtraie", latitude: 47.1, longitude: 6.1, target: "cepes", altClass: 450, t: ["boletus_edulis": 0.6])
        #expect(server.coinNames == ["Col", "Hêtraie"])
        let col = try #require(model.coins.first { $0.name == "Col" })

        // hors ligne : la suppression reste sur l'appareil
        server.fail(503)
        await model.removeCoin(col.id)
        #expect(model.coins.map(\.name) == ["Hêtraie"])
        server.fail(nil)
        #expect(server.coinNames == ["Col", "Hêtraie"])

        // lancement suivant, en ligne : le serveur a encore « Col », la fusion ne le reprend pas
        let next = Self.model(host: host, directory: directory, identity: identity)
        await next.start(api: next.api)
        #expect(next.coins.map(\.name) == ["Hêtraie"])
        #expect(server.coinNames == ["Hêtraie"])  // et la suppression est arrivée au serveur
    }

    @Test("Supprimé ou renommé sur un autre appareil : l'appareil suit, sans rien renvoyer")
    func changesFromAnotherDevice() async throws {
        let directory = FieldStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (server, host) = Self.server()
        let identity = IdentityProvider.inMemory()
        let model = Self.model(host: host, directory: directory, identity: identity)
        await model.start(api: model.api)
        await model.addCoin(name: "Col", latitude: 47.0, longitude: 6.0, target: "cepes", altClass: 750, t: ["boletus_edulis": 0.8])
        await model.addCoin(name: "Hêtraie", latitude: 47.1, longitude: 6.1, target: "cepes", altClass: 450, t: ["boletus_edulis": 0.6])
        let col = try #require(model.coins.first { $0.name == "Col" })
        var renamed = try #require(model.coins.first { $0.name == "Hêtraie" })
        renamed.name = "Hêtraie du col"

        // l'autre appareil supprime « Col », renomme « Hêtraie » et ajoute « Sapinière »
        let added = Self.coin("Sapinière")
        server.set(coins: [renamed, added])
        let puts = Self.methods(host).filter { $0 == "PUT /coins" }.count

        let next = Self.model(host: host, directory: directory, identity: identity)
        await next.start(api: next.api)
        #expect(next.coins.map(\.name).sorted() == ["Hêtraie du col", "Sapinière"])
        #expect(!next.coins.contains { $0.id == col.id })
        #expect(Self.methods(host).filter { $0 == "PUT /coins" }.count == puts)  // rien à renvoyer
        #expect(server.coinNames == ["Hêtraie du col", "Sapinière"])
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

    @Test("Adresse d'API non officielle : lecture seule, rien de privé ne part, rien n'est effacé de l'appareil")
    func readOnlyWithCustomAddress() async throws {
        let directory = FieldStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = StubURLProtocol.host()
        StubURLProtocol.set(host: host) { _, _, _ in (200, "{}") }
        let model = Self.model(host: host, directory: directory, trusted: false)
        await model.start(api: model.api)
        #expect(model.userID != nil)

        await model.record(species: "boletus_edulis", latitude: 47.0, longitude: 6.0, accuracyM: nil, date: "2026-11-13", found: true, quantity: 1)
        await model.addCoin(name: "Col", latitude: 47.0, longitude: 6.0, target: "cepes", altClass: 750, t: ["boletus_edulis": 0.8])
        await model.refreshCoinScores()
        // gardés sur l'appareil, en attente ; aucune requête, donc ni identifiant ni donnée privée
        #expect(model.observations.count == 1 && model.pendingCount == 1)
        #expect(model.coins.count == 1)
        #expect(StubURLProtocol.requests(host: host).isEmpty)

        // « tout supprimer » n'efface pas l'appareil sans effacer le serveur
        await model.deleteAll()
        #expect(StubURLProtocol.requests(host: host).isEmpty)
        #expect(model.observations.count == 1 && model.coins.count == 1)
        let problem = try #require(model.problem)
        #expect(problem.text.hasPrefix("Rien n'a été effacé"))
        #expect(!problem.retryable)

        // retour à l'adresse officielle : ce qui attendait part
        StubURLProtocol.set(host: host) { method, path, _ in
            switch (method, path) {
            case ("POST", "/observations"): (201, #"{"inserted": 1, "duplicates": 0}"#)
            case ("PUT", "/coins"): (200, #"{"coins": 1, "notifications": false}"#)
            case ("GET", "/coins"): (200, #"{"today": "2026-11-13", "coins": []}"#)
            case ("GET", "/observations"): (200, #"{"count": 0, "observations": []}"#)
            default: (404, #"{"detail": "inconnu"}"#)
            }
        }
        await model.start(api: StubURLProtocol.api(host: host))
        #expect(model.pendingCount == 0)
        let user = try #require(model.userID)
        #expect(StubURLProtocol.requests(host: host).contains { $0.method == "POST" && $0.user == user.uuidString.lowercased() })
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
        let (_, host) = Self.server()
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
        #expect(model.coinScores[coin.id]?.summary == ["pleine saison"])
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
