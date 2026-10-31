import Foundation

/// Observation terrain (skill `field-feedback`) : un signalement technique, privé, jamais partagé.
/// Nommée `FieldObservation` pour ne pas masquer le module `Observation` de la macro `@Observable`.
/// Même forme que `POST /observations` : clés `snake_case` explicites.
nonisolated struct FieldObservation: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var species: String
    var lat: Double
    var lon: Double
    /// Précision GPS en mètres au moment de l'enregistrement, si connue.
    var accuracyM: Double?
    /// Jour civil local, ISO (`2026-10-31`) : la sortie a pu être le matin.
    var date: String
    var found: Bool
    /// 1 quelques-uns, 2 un bon panier, 3 beaucoup ; `nil` quand rien n'a été trouvé.
    var quantity: Int?

    enum CodingKeys: String, CodingKey {
        case id, species, lat, lon, date, found, quantity
        case accuracyM = "accuracy_m"
    }

    init(
        id: UUID = UUID(), species: String, lat: Double, lon: Double, accuracyM: Double? = nil,
        date: String, found: Bool, quantity: Int?
    ) {
        self.id = id
        self.species = species
        self.lat = lat
        self.lon = lon
        self.accuracyM = accuracyM
        self.date = date
        self.found = found
        self.quantity = found ? quantity : nil
    }
}

/// Un coin : favori nommé, privé, synchronisé en liste complète par `PUT /coins`.
nonisolated struct Coin: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var lat: Double
    var lon: Double
    /// Espèce ou groupe choisi sur la carte.
    var target: String
    /// Centre de la classe d'altitude du pixel, en mètres.
    var altClass: Int
    /// Espèce → `T` du pixel, lu dans les tuiles : le backend n'a que la météo.
    var t: [String: Double]

    enum CodingKeys: String, CodingKey {
        case id, name, lat, lon, target, t
        case altClass = "alt_class"
    }

    init(id: UUID = UUID(), name: String, lat: Double, lon: Double, target: String, altClass: Int, t: [String: Double]) {
        self.id = id
        self.name = name
        self.lat = lat
        self.lon = lon
        self.target = target
        self.altClass = altClass
        self.t = t
    }
}

/// Un coin tel que `GET /coins` le renvoie : avec le score du jour calculé par le backend.
nonisolated struct ScoredCoin: Decodable, Hashable, Identifiable, Sendable {
    let id: UUID
    let name: String
    /// `nil` : pas de météo pour la cellule.
    let score: Double?
    /// Espèce qui porte le score du jour.
    let leading: String?
    /// Meilleur jour à venir (strictement meilleur que J), ISO.
    let bestDay: String?
    let best: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, score, leading, best
        case bestDay = "best_day"
    }
}

nonisolated struct CoinsResponse: Decodable, Sendable {
    let today: String
    let coins: [ScoredCoin]
}

nonisolated struct ObservationsResponse: Decodable, Sendable {
    let count: Int
    let observations: [FieldObservation]
}

nonisolated struct ObservationsPostResponse: Decodable, Sendable {
    let inserted: Int
    let duplicates: Int
}

nonisolated struct DeleteResponse: Decodable, Sendable {
    let deleted: Int
}

nonisolated struct PutCoinsResponse: Decodable, Sendable {
    let coins: Int
    let notifications: Bool
}

/// Corps de `POST /observations`.
nonisolated struct ObservationsBatch: Encodable, Sendable {
    let observations: [FieldObservation]
}

/// Corps de `PUT /coins` : liste complète, jeton APNs facultatif (absent = pas de notification).
nonisolated struct CoinsBody: Encodable, Sendable {
    let apnsToken: String?
    let sandbox: Bool
    let coins: [Coin]

    enum CodingKeys: String, CodingKey {
        case sandbox, coins
        case apnsToken = "apns_token"
    }
}
