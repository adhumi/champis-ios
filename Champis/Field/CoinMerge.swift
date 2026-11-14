import Foundation

/// Fusion des coins de l'appareil avec ceux du serveur (décision du 13 nov. 2026). `PUT /coins`
/// remplace la liste du serveur : envoyer la liste d'un appareil sans avoir lu celle du serveur
/// effaçait les coins créés sur un autre. L'app lit donc `GET /coins` au démarrage et fusionne
/// avant tout `PUT`.
///
/// Les coins n'ont pas d'horodatage. La fusion se fait à trois : la liste de l'appareil, celle du
/// serveur, et la **base**, c'est-à-dire la liste que le serveur avait au dernier échange réussi
/// avec cet appareil (gardée dans `coins.json`). La base dit ce qui a changé ici depuis, et sert
/// de pierre tombale : un coin de la base absent de l'appareil y a été supprimé.
///
/// Par `id` :
/// - sur l'appareil seulement : gardé s'il n'a jamais été envoyé ou s'il a été modifié ici depuis
///   la base ; retiré s'il est dans la base, inchangé (il a été supprimé sur un autre appareil) ;
/// - sur le serveur seulement : ajouté s'il n'est pas dans la base (créé sur un autre appareil) ;
///   ignoré s'il y est (supprimé ici, peut-être hors ligne : il n'est pas ressuscité) ;
/// - des deux côtés : la version de l'appareil si elle a changé depuis la base (ou sans base),
///   sinon celle du serveur (renommé sur un autre appareil).
nonisolated enum CoinMerge {
    nonisolated struct Outcome: Equatable, Sendable {
        /// La liste fusionnée : les coins de l'appareil dans leur ordre, puis ceux venus du serveur.
        let coins: [Coin]
        /// Vrai si la liste fusionnée diffère de celle du serveur : un `PUT` est à faire.
        let needsPush: Bool
    }

    static func merge(local: [Coin], remote: [Coin], base: [Coin]) -> Outcome {
        let baseByID = index(base)
        let remoteByID = index(remote)
        var merged: [Coin] = []
        var seen: Set<UUID> = []
        for coin in local where seen.insert(coin.id).inserted {
            let changedHere = baseByID[coin.id] != coin
            if let theirs = remoteByID[coin.id] {
                merged.append(changedHere ? coin : theirs)
            } else if changedHere {
                merged.append(coin)
            }
        }
        for coin in remote where seen.insert(coin.id).inserted {
            if baseByID[coin.id] == nil {
                merged.append(coin)
            }
        }
        return Outcome(coins: merged, needsPush: !same(merged, remote))
    }

    /// Mêmes coins (identifiants et contenu), quel que soit l'ordre.
    static func same(_ a: [Coin], _ b: [Coin]) -> Bool {
        index(a) == index(b)
    }

    private static func index(_ coins: [Coin]) -> [UUID: Coin] {
        Dictionary(coins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
