import Foundation
import Testing
@testable import Champis

/// Étape B4 (6 nov. 2026) : messages d'erreur en clair, cause en mots quand on la connaît, détail
/// technique à part (derrière « Détails »).
struct ProblemTests {
    @Test("Réseau absent : la cause en mots, le code système dans le détail")
    func offline() {
        let problem = Problem("Météo indisponible", error: URLError(.notConnectedToInternet))
        #expect(problem.text == "Météo indisponible : pas de connexion à Internet")
        #expect(problem.detail?.hasPrefix("URLError -1009") == true)
        #expect(problem.retryable)
        #expect(Problem.cause(of: URLError(.timedOut)) == "le serveur met trop de temps à répondre")
        #expect(Problem.cause(of: URLError(.cannotFindHost)) == "le serveur est injoignable")
    }

    @Test("Serveur : 503 et 5xx en mots, le detail de l'API à part ; un 404 n'invente pas de cause")
    func server() {
        let unavailable = Problem("Score des coins indisponible", error: ChampisAPI.Failure.http(status: 503, detail: "base indisponible"))
        #expect(unavailable.text == "Score des coins indisponible : le serveur est momentanément indisponible")
        #expect(unavailable.detail == "HTTP 503 : base indisponible")
        #expect(Problem.cause(of: ChampisAPI.Failure.http(status: 500, detail: "")) == "le serveur a rencontré une erreur")

        let missing = Problem("Ce point n'a pas pu être lu", error: ChampisAPI.Failure.http(status: 404, detail: ""))
        #expect(missing.text == "Ce point n'a pas pu être lu")
        #expect(missing.detail == "HTTP 404")
    }

    @Test("Réponse illisible : dite comme telle")
    func decoding() {
        do {
            _ = try JSONDecoder().decode(Int.self, from: Data(#""pas un nombre""#.utf8))
            Issue.record("le décodage aurait dû échouer")
        } catch {
            #expect(Problem.cause(of: error)?.contains("illisible") == true)
        }
    }

    @Test("Itinéraire d'un coin : destination dans Plans")
    func directions() {
        let url = PointSheet.directionsURL(latitude: 46.9, longitude: 6.35)
        #expect(url?.absoluteString == "https://maps.apple.com/?daddr=46.900000,6.350000")
    }
}
