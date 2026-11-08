import Foundation

/// Observations et coins : les appels où l'identifiant de l'app (`X-Champis-User`) est obligatoire,
/// donné explicitement ; depuis le lot BO2 (8 nov. 2026) les autres requêtes à l'API le portent
/// aussi, par `userID`, pour le compte des appareils actifs.
nonisolated extension ChampisAPI {
    /// Lot idempotent : renvoyer le même lot après une coupure ne crée pas de doublon.
    func postObservations(_ observations: [FieldObservation], user: UUID) async throws -> ObservationsPostResponse {
        let body = try JSONEncoder().encode(ObservationsBatch(observations: observations))
        let data = try await send("POST", "observations", body: body, user: user)
        return try JSONDecoder().decode(ObservationsPostResponse.self, from: data)
    }

    /// Mes observations ; celles des autres n'existent pas côté client.
    func observations(user: UUID) async throws -> ObservationsResponse {
        let data = try await send("GET", "observations", user: user)
        return try JSONDecoder().decode(ObservationsResponse.self, from: data)
    }

    /// Efface toutes mes lignes : observations, coins, jeton (droit RGPD).
    func deleteObservations(user: UUID) async throws -> DeleteResponse {
        let data = try await send("DELETE", "observations", user: user)
        return try JSONDecoder().decode(DeleteResponse.self, from: data)
    }

    /// Liste complète : le serveur remplace, il ne fusionne pas.
    func putCoins(_ coins: [Coin], apnsToken: String?, sandbox: Bool, user: UUID) async throws -> PutCoinsResponse {
        let body = try JSONEncoder().encode(CoinsBody(apnsToken: apnsToken, sandbox: sandbox, coins: coins))
        let data = try await send("PUT", "coins", body: body, user: user)
        return try JSONDecoder().decode(PutCoinsResponse.self, from: data)
    }

    /// Mes coins avec leur score du jour et le meilleur jour à venir, calculés par le backend.
    func coins(user: UUID) async throws -> CoinsResponse {
        let data = try await send("GET", "coins", user: user)
        return try JSONDecoder().decode(CoinsResponse.self, from: data)
    }
}
