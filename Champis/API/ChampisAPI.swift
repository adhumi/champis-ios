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
/// sur `champis.app`). Sans état ; les réponses sont décodées hors du MainActor.
///
/// L'identifiant pseudonyme de l'app (`userID`, skill `field-feedback`) part en en-tête
/// `X-Champis-User` de **toutes** les requêtes à l'API (spec › Backoffice › Usage, tranché le
/// 8 nov. 2026) : le serveur n'en garde qu'une empreinte hachée par jour pour compter les appareils
/// actifs, jamais l'identifiant ; rien ne part au site.
nonisolated struct ChampisAPI: Sendable {
    nonisolated enum Failure: Error, LocalizedError, Equatable {
        case badURL
        /// Code HTTP et `detail` de FastAPI (422 « zoomez », 503 météo indisponible…).
        case http(status: Int, detail: String)

        var errorDescription: String? {
            switch self {
            case .badURL: "Adresse de l'API invalide"
            case .http(let status, let detail): detail.isEmpty ? "Erreur HTTP \(status)" : detail
            }
        }
    }

    /// Le site, qui garde les fichiers qui ne sont pas à l'API depuis le découpage des dépôts
    /// (spec › Produit › Étape C, lot C7, 6 nov. 2026) : les limites des départements.
    static let defaultSiteURL = URL(string: "https://champis.app")!

    let baseURL: URL
    let siteURL: URL
    let session: URLSession
    /// Identifiant pseudonyme de l'app, envoyé sur toutes les requêtes à l'API ; `nil` quand aucun
    /// magasin d'identité ne répond (rien n'est envoyé).
    let userID: UUID?

    init(
        baseURL: URL, siteURL: URL = ChampisAPI.defaultSiteURL, session: URLSession = .shared, userID: UUID? = nil
    ) {
        self.baseURL = baseURL
        self.siteURL = siteURL
        self.session = session
        self.userID = userID
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

    /// Indice par département (bandeau des jours), 11 jours, pour les espèces données.
    func departements(species: [String]) async throws -> DepartementsResponse {
        try await get("departements", query: species.map { URLQueryItem(name: "species", value: $0) })
    }

    /// Limites des départements (GeoJSON Admin Express simplifié), un fichier du site sous `/web/` :
    /// l'API ne sert plus le site depuis le découpage des dépôts.
    func departementsGeoJSON() async throws -> Data {
        try await send("GET", "web/departements.geojson", on: siteURL)
    }

    /// URL absolue d'un fichier du manifeste (relative à l'API en mode proxy).
    func tileURL(_ entry: TilesManifest.Entry) -> URL? {
        URL(string: entry.url, relativeTo: baseURL)?.absoluteURL
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
    /// sinon `userID`, et jamais rien vers une autre adresse que l'API (`on` : le site pour ses
    /// propres fichiers).
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
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let user = user ?? (base == nil ? userID : nil) {
            request.setValue(user.uuidString.lowercased(), forHTTPHeaderField: Self.userHeader)
        }
        let (data, response) = try await session.data(for: request)
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
