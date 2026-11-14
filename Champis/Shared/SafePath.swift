import Foundation

/// Noms venus du serveur qui servent de chemins sur l'appareil (audit du 13 nov. 2026) : le code
/// d'un département et le nom d'un fichier PMTiles du manifeste `GET /tiles` deviennent un dossier
/// et un fichier d'Application Support. Ils sont contrôlés au décodage du manifeste, et la
/// destination l'est encore avant toute écriture ou suppression : jamais hors de la racine.
nonisolated enum SafePath {
    /// Code de département tel que le pipeline le publie : deux ou trois chiffres (`01`, `25`,
    /// `95`), ou `2A` et `2B` pour la Corse.
    static func isDepartment(_ code: String) -> Bool {
        if code == "2A" || code == "2B" { return true }
        let bytes = Array(code.utf8)
        return (2...3).contains(bytes.count) && bytes.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// Un seul composant de chemin : lettres ASCII, chiffres, `.`, `_`, `-`, sans `..`, ni vide ni `.`.
    static func isComponent(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= 200, name != ".", !name.contains("..") else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2E || byte == 0x5F || byte == 0x2D
        }
    }

    /// Nom d'un fichier du manifeste : un composant sûr qui finit par `.pmtiles`.
    static func isTileFileName(_ name: String) -> Bool {
        isComponent(name) && name.hasSuffix(".pmtiles") && name.count > ".pmtiles".count
    }

    /// Composants du chemin une fois `.` et `..` résolus, sans consulter le disque ; `nil` si le
    /// chemin remonte au-dessus de la racine du système de fichiers.
    static func components(of url: URL) -> [String]? {
        var out: [String] = []
        for part in url.path(percentEncoded: false).split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                guard !out.isEmpty else { return nil }
                out.removeLast()
                continue
            }
            out.append(String(part))
        }
        return out
    }

    /// Vrai si `url`, une fois standardisée, est strictement sous `root`.
    static func isContained(_ url: URL, in root: URL) -> Bool {
        guard url.isFileURL, root.isFileURL, let path = components(of: url), let base = components(of: root) else {
            return false
        }
        return path.count > base.count && Array(path.prefix(base.count)) == base
    }

    /// Chemin refusé : nom invalide ou destination hors de la racine.
    nonisolated struct Refused: Error, LocalizedError, Equatable {
        let name: String

        var errorDescription: String? { "Chemin refusé : \(name)" }
    }

    /// `url` si elle est sous `root`, sinon `Refused`.
    static func checked(_ url: URL, in root: URL) throws -> URL {
        guard isContained(url, in: root) else { throw Refused(name: url.lastPathComponent) }
        return url
    }
}
