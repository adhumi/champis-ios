import Foundation

/// Un message d'erreur en clair (étape B4, 6 nov. 2026, audit U12) : ce qui arrive et, quand on la
/// connaît, la cause en mots (« pas de connexion à Internet ») ; le détail technique (code HTTP,
/// message système, chemin d'API) reste à part, montré seulement derrière « Détails ».
nonisolated struct Problem: Equatable, Sendable {
    /// Phrase en clair, sans jargon ni point final.
    let text: String
    /// Détail technique, à la demande.
    let detail: String?
    /// « Réessayer » a un sens (réseau, serveur) ; faux pour un état qui ne changera pas seul.
    let retryable: Bool

    init(_ text: String, detail: String? = nil, retryable: Bool = true) {
        self.text = text
        self.detail = detail
        self.retryable = retryable
    }

    /// `text`, puis la cause en mots quand on sait la dire : « Météo indisponible : pas de
    /// connexion à Internet ». Le message brut de l'erreur part dans `detail`.
    init(_ text: String, error: any Error, retryable: Bool = true) {
        let cause = Self.cause(of: error)
        self.init(cause.map { "\(text) : \($0)" } ?? text, detail: Self.technical(error), retryable: retryable)
    }

    /// Cause en mots d'une erreur de réseau ou du serveur ; `nil` quand on ne sait pas la dire simplement.
    static func cause(of error: any Error) -> String? {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return "pas de connexion à Internet"
            case .timedOut:
                return "le serveur met trop de temps à répondre"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "le serveur est injoignable"
            default:
                return nil
            }
        }
        if let failure = error as? ChampisAPI.Failure, case .http(let status, _) = failure {
            switch status {
            case 503: return "le serveur est momentanément indisponible"
            case 500...599: return "le serveur a rencontré une erreur"
            default: return nil
            }
        }
        if error is DecodingError {
            return "réponse du serveur illisible, l'app est peut-être à mettre à jour"
        }
        return nil
    }

    /// Le détail technique : code HTTP et `detail` de l'API, code et message système.
    static func technical(_ error: any Error) -> String {
        if let failure = error as? ChampisAPI.Failure {
            switch failure {
            case .badURL:
                return "Adresse de l'API invalide"
            case .http(let status, let detail):
                return detail.isEmpty ? "HTTP \(status)" : "HTTP \(status) : \(detail)"
            case .readOnly:
                return "Adresse d'API non officielle : rien de privé n'est envoyé"
            }
        }
        if let url = error as? URLError {
            return "URLError \(url.code.rawValue) : \(url.localizedDescription)"
        }
        return String(describing: error)
    }
}
