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
}

/// Client de champis-api (`/species`, `/tiles`, `/weather/bbox`). Sans état ; les réponses sont
/// décodées hors du MainActor.
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

    let baseURL: URL
    let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
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

    /// URL absolue d'un fichier du manifeste (relative à l'API en mode proxy).
    func tileURL(_ entry: TilesManifest.Entry) -> URL? {
        URL(string: entry.url, relativeTo: baseURL)?.absoluteURL
    }

    @concurrent
    private func get<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw Failure.badURL
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else { throw Failure.badURL }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.http(status: status, detail: Self.detail(in: data))
        }
        return try JSONDecoder().decode(T.self, from: data)
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
