import Foundation

/// Emprise géographique en degrés (WGS 84).
nonisolated struct BBox: Hashable, Sendable {
    var minLon: Double
    var minLat: Double
    var maxLon: Double
    var maxLat: Double

    /// Marge en degrés de chaque côté (la carte web prend 0,1°, à peu près une cellule météo).
    func padded(by degrees: Double) -> BBox {
        BBox(minLon: minLon - degrees, minLat: minLat - degrees, maxLon: maxLon + degrees, maxLat: maxLat + degrees)
    }

    /// Vrai si `other` tient entièrement dans cette emprise (bords compris).
    func contains(_ other: BBox) -> Bool {
        minLon <= other.minLon && minLat <= other.minLat && maxLon >= other.maxLon && maxLat >= other.maxLat
    }
}

/// Client de champis-api (`/species`, `/tiles`, `/weather`, `/weather/bbox`, `/weather/field`,
/// `/departements`, sur `api.champis.app`) et du site pour ses fichiers (`/web/departements.geojson`,
/// `/shared/photos/<espèce>.jpg`, sur `champis.app`). Sans état ; les réponses sont décodées hors du MainActor.
///
/// L'identifiant pseudonyme de l'app (`userID`, skill `field-feedback`) part en en-tête
/// `X-Champis-User` de **toutes** les requêtes à l'API (spec › Backoffice › Usage, tranché le
/// 8 nov. 2026) : le serveur n'en garde qu'une empreinte hachée par jour pour compter les appareils
/// actifs, jamais l'identifiant ; rien ne part au site.
///
/// L'adresse de l'API reste un réglage, mais borné (décision du 13 nov. 2026) : https exigé, et
/// l'identifiant comme toute donnée privée (observations, coins, tout `PUT`, `POST` ou `DELETE`)
/// ne partent que vers l'hôte officiel `api.champis.app` (`isOfficial`). Avec une autre adresse,
/// l'app lit seulement, sans identifiant : catalogue, météo, tuiles.
nonisolated struct ChampisAPI: Sendable {
    nonisolated enum Failure: Error, LocalizedError, Equatable {
        case badURL
        /// Code HTTP et `detail` de FastAPI (422 « zoomez », 503 météo indisponible…).
        case http(status: Int, detail: String)
        /// L'adresse réglée n'est pas l'API officielle : rien de privé n'y est envoyé.
        case readOnly

        var errorDescription: String? {
            switch self {
            case .badURL: "Adresse de l'API invalide"
            case .http(let status, let detail): detail.isEmpty ? "Erreur HTTP \(status)" : detail
            case .readOnly: "Adresse d'API non officielle : lecture seule"
            }
        }
    }

    /// Le seul hôte qui reçoit l'identifiant de l'app, les observations et les coins.
    static let officialHost = "api.champis.app"
    static let officialBaseURL = URL(string: "https://api.champis.app")!

    /// Une adresse d'API acceptable dans les réglages : https, un hôte, pas d'identifiants dans
    /// l'adresse. En développement seulement (`DEBUG`), http vers la machine locale (API lancée
    /// par `make serve` de champis-api).
    static func isAcceptable(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased(), !host.isEmpty, url.user() == nil, url.password() == nil else { return false }
        let scheme = url.scheme?.lowercased()
        if scheme == "https" { return true }
        #if DEBUG
        return scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)
        #else
        return false
        #endif
    }

    /// Adresse https tirée d'un texte venu du serveur (lien d'une fiche) ; `nil` pour tout autre
    /// schéma : l'app n'ouvre pas `tel:`, `file:` ou un schéma d'une autre app sur la foi d'une donnée.
    static func httpsURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    /// Le site, qui garde les fichiers qui ne sont pas à l'API depuis le découpage des dépôts
    /// (spec › Produit › Étape C, lot C7, 6 nov. 2026) : les limites des départements, et le
    /// référentiel sous `/shared/` (photos des fiches).
    static let defaultSiteURL = URL(string: "https://champis.app")!

    let baseURL: URL
    let siteURL: URL
    let session: URLSession
    /// Identifiant pseudonyme de l'app, envoyé sur toutes les requêtes à l'API ; `nil` quand aucun
    /// magasin d'identité ne répond (rien n'est envoyé).
    let userID: UUID?
    /// Hôte de confiance pour l'identifiant et les données privées : `officialHost` dans l'app ;
    /// les tests, dont le serveur factice a un hôte par test, donnent le leur.
    let trustedHost: String

    init(
        baseURL: URL, siteURL: URL = ChampisAPI.defaultSiteURL, session: URLSession = .shared, userID: UUID? = nil,
        trustedHost: String = ChampisAPI.officialHost
    ) {
        self.baseURL = baseURL
        self.siteURL = siteURL
        self.session = session
        self.userID = userID
        self.trustedHost = trustedHost
    }

    /// Vrai si `baseURL` est l'API officielle en https : la seule adresse qui reçoit l'identifiant,
    /// les observations et les coins.
    var isOfficial: Bool {
        baseURL.scheme?.lowercased() == "https" && baseURL.host()?.lowercased() == trustedHost.lowercased()
            && (baseURL.port == nil || baseURL.port == 443) && baseURL.user() == nil
    }

    func species() async throws -> SpeciesCatalog {
        try await get("species")
    }

    func tiles() async throws -> TilesManifest {
        try await get("tiles")
    }

    /// Météo de l'emprise pour les espèces données (toutes si vide), 11 jours.
    func weather(bbox: BBox, species: [String]) async throws -> WeatherBBoxResponse {
        var query = [
            URLQueryItem(name: "min_lon", value: Self.format(bbox.minLon)),
            URLQueryItem(name: "min_lat", value: Self.format(bbox.minLat)),
            URLQueryItem(name: "max_lon", value: Self.format(bbox.maxLon)),
            URLQueryItem(name: "max_lat", value: Self.format(bbox.maxLat)),
        ]
        query += species.map { URLQueryItem(name: "species", value: $0) }
        return try await get("weather/bbox", query: query)
    }

    /// Champ météo compact d'un seul jour (`M_eff × Φ` par cellule, espèce et classe d'altitude) sur
    /// l'emprise, sans plafond de cellules : la carte sous le zoom 9 (décision du 4 nov. 2026).
    /// `day` hors de J−3 → J+7 : 422.
    func weatherField(bbox: BBox, species: [String], day: String) async throws -> WeatherFieldResponse {
        var query = species.map { URLQueryItem(name: "species", value: $0) }
        query += [
            URLQueryItem(name: "day", value: day),
            URLQueryItem(name: "min_lon", value: Self.format(bbox.minLon)),
            URLQueryItem(name: "min_lat", value: Self.format(bbox.minLat)),
            URLQueryItem(name: "max_lon", value: Self.format(bbox.maxLon)),
            URLQueryItem(name: "max_lat", value: Self.format(bbox.maxLat)),
        ]
        return try await get("weather/field", query: query)
    }

    /// Détail d'une cellule pour la fiche : mêmes lignes que `/weather/bbox`, avec `factors`.
    func weatherDetail(cell: String, species: [String]) async throws -> CellWeather {
        let query = [URLQueryItem(name: "cell", value: cell)] + species.map { URLQueryItem(name: "species", value: $0) }
        return try await get("weather", query: query)
    }

    /// Détail de la cellule la plus proche d'un point (`GET /weather?lat=&lon=`) : la fiche d'un coin
    /// ouverte depuis Mes coins, quand la carte n'a pas la météo de cet endroit (18 nov. 2026).
    func weatherDetail(latitude: Double, longitude: Double, species: [String]) async throws -> CellWeather {
        let query = [
            URLQueryItem(name: "lat", value: Self.format(latitude)),
            URLQueryItem(name: "lon", value: Self.format(longitude)),
        ] + species.map { URLQueryItem(name: "species", value: $0) }
        return try await get("weather", query: query)
    }

    /// Indice par département (bandeau des jours), 11 jours, pour les espèces données.
    func departements(species: [String]) async throws -> DepartementsResponse {
        try await get("departements", query: species.map { URLQueryItem(name: "species", value: $0) })
    }

    /// Limites des départements (GeoJSON Admin Express simplifié), un fichier du site sous `/web/` :
    /// l'API ne sert plus le site depuis le découpage des dépôts.
    func departementsGeoJSON() async throws -> Data {
        try await send("GET", "web/departements.geojson", on: siteURL)
    }

    /// Photo de la fiche d'une espèce : la copie du référentiel (`shared/photos/<id>.jpg`) servie
    /// par le site, comme les autres fichiers du référentiel. Plus aucune requête vers Wikimedia
    /// Commons, qui recevait l'adresse du lecteur à l'ouverture d'une fiche (décision du
    /// 13 nov. 2026) ; le crédit reste affiché sous l'image. `nil` si l'identifiant n'est pas un
    /// simple nom.
    func photoURL(species id: String) -> URL? {
        guard SafePath.isComponent(id) else { return nil }
        return siteURL.appending(path: "shared/photos/\(id).jpg")
    }

    /// URL absolue d'un fichier du manifeste (relative à l'API en mode proxy) ; https exigé, sauf
    /// pour un fichier servi par l'API elle-même (même schéma, même hôte, même port : l'API locale
    /// en développement). Les tuiles se lisent sans identifiant.
    func tileURL(_ entry: TilesManifest.Entry) -> URL? {
        guard let url = URL(string: entry.url, relativeTo: baseURL)?.absoluteURL else { return nil }
        if url.scheme?.lowercased() == "https" { return url }
        let sameOrigin = url.scheme == baseURL.scheme && url.host() == baseURL.host() && url.port == baseURL.port
        return sameOrigin ? url : nil
    }

    @concurrent
    private func get<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await getData(path, query: query))
    }

    @concurrent
    private func getData(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await send("GET", path, query: query)
    }

    /// En-tête qui porte l'identifiant de l'app (contrat spec › Backend, 30 oct. 2026).
    static let userHeader = "X-Champis-User"

    /// Requête générique : `body` est un JSON ; l'en-tête d'identité porte `user` s'il est donné,
    /// sinon `userID`, et jamais rien vers une autre adresse que l'API officielle (`on` : le site
    /// pour ses propres fichiers). Une requête privée (`user` donné, ou autre méthode que `GET`)
    /// vers une autre adresse est refusée avant de partir (`Failure.readOnly`).
    @concurrent
    func send(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, user: UUID? = nil,
        on base: URL? = nil
    ) async throws -> Data {
        guard var components = URLComponents(
            url: (base ?? baseURL).appending(path: path), resolvingAgainstBaseURL: false
        ) else {
            throw Failure.badURL
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else { throw Failure.badURL }
        let trusted = base == nil && isOfficial
        if user != nil || method != "GET" {
            guard trusted else { throw Failure.readOnly }
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if trusted, let user = user ?? userID {
            request.setValue(user.uuidString.lowercased(), forHTTPHeaderField: Self.userHeader)
        }
        let (data, response) = try await session.data(for: request, delegate: RedirectGuard())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.http(status: status, detail: Self.detail(in: data))
        }
        return data
    }

    /// `{"detail": "…"}` de FastAPI, sinon le corps brut (tronqué).
    static func detail(in data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = object["detail"] as? String {
            return detail
        }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }

    static func format(_ value: Double) -> String {
        String(format: "%.5f", locale: nil, value)
    }
}

/// Délégué des requêtes à l'API : une redirection qui change d'hôte (ou quitte https) repart sans
/// l'en-tête `X-Champis-User`. `URLSession` recopie sinon les en-têtes de la requête d'origine
/// sur la requête redirigée, et l'identifiant suivrait vers un hôte qui n'est pas l'API.
nonisolated final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(Self.redirected(request, from: task.originalRequest?.url))
    }

    /// La requête redirigée, sans l'identifiant si elle ne va plus au même hôte en https.
    static func redirected(_ request: URLRequest, from original: URL?) -> URLRequest {
        var request = request
        let sameHost = request.url?.host()?.lowercased() == original?.host()?.lowercased() && original?.host() != nil
        let https = request.url?.scheme?.lowercased() == "https"
        if !(sameHost && https) {
            request.setValue(nil, forHTTPHeaderField: ChampisAPI.userHeader)
        }
        return request
    }
}
