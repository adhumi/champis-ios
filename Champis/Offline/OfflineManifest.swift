import Foundation

/// Un fichier PMTiles d'un département téléchargé (skill `offline`).
nonisolated struct OfflineFile: Codable, Hashable, Sendable {
    let name: String
    /// `T` (une espèce), `G` (un groupe, un canal par espèce) `A` (classes d'altitude) ou `E` (altitude fine, à la place de `A` quand le jeu la publie).
    let kind: String
    let species: String?
    let url: String
    var bytes: Int64
    var done: Bool
    /// Espèces d'un `G` dans l'ordre des canaux (manifeste `species`) ; absent pour `T` et `A`, et
    /// dans les `offline.json` antérieurs au 5 nov. 2026.
    var channels: [String]? = nil
}

/// Un département embarqué : ses fichiers, la météo du moment du téléchargement et les dates.
/// Il n'est disponible hors ligne que lorsque tout est écrit (`complete`) : rien à moitié.
nonisolated struct OfflineDepartment: Codable, Hashable, Identifiable, Sendable {
    let code: String
    var name: String?
    var species: [String]
    var files: [OfflineFile]
    /// `today` de la météo embarquée (les 11 jours J−3 → J+7 autour de ce jour).
    var weatherToday: String?
    /// Horodatage ISO 8601 de la récupération de la météo.
    var weatherFetchedAt: String?
    /// `generated` du manifeste des tuiles au moment du téléchargement.
    var tilesGenerated: String?
    var scoringVersion: String?
    var error: String?

    var id: String { code }
    var filesDone: Bool { !files.isEmpty && files.allSatisfy(\.done) }
    var complete: Bool { filesDone && weatherToday != nil }
    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

nonisolated struct OfflineManifest: Codable, Sendable {
    var version = 1
    var departments: [String: OfflineDepartment] = [:]
}

/// Fichier local à proposer au lecteur de tuiles avant la source distante.
nonisolated struct OfflineLocalFile: Hashable, Sendable {
    let kind: String
    let species: String?
    let url: URL
    /// Espèces d'un `G` dans l'ordre des canaux.
    var channels: [String]? = nil
}

nonisolated extension BBox {
    /// France métropolitaine et Corse, marge comprise : les bornes que l'API accepte pour un point
    /// (`lat` de 41,0 à 51,5, `lon` de −5,5 à 10,0).
    static let france = BBox(minLon: -5.5, minLat: 41.0, maxLon: 10.0, maxLat: 51.5)

    /// Partie de cette emprise contenue dans `other` ; `nil` si elles ne se recoupent pas ou si une
    /// borne n'est pas un nombre fini.
    func clamped(to other: BBox) -> BBox? {
        guard [minLon, minLat, maxLon, maxLat].allSatisfy(\.isFinite) else { return nil }
        let clamped = BBox(
            minLon: max(minLon, other.minLon), minLat: max(minLat, other.minLat),
            maxLon: min(maxLon, other.maxLon), maxLat: min(maxLat, other.maxLat)
        )
        guard clamped.minLon <= clamped.maxLon, clamped.minLat <= clamped.maxLat else { return nil }
        return clamped
    }

    /// Découpe en sous-emprises d'au plus `maxSpan` degrés de côté : `GET /weather/bbox` refuse plus
    /// de 40 cellules de 5 km, un département en compte des centaines. Une emprise retournée, non
    /// finie ou plus grande que la France ne se découpe pas (liste vide) : le nombre de
    /// sous-emprises, donc de requêtes, reste borné quoi que dise l'en-tête d'un fichier.
    func split(maxSpan: Double) -> [BBox] {
        guard maxSpan > 0, maxSpan.isFinite, [minLon, minLat, maxLon, maxLat].allSatisfy(\.isFinite),
              maxLon >= minLon, maxLat >= minLat,
              maxLon - minLon <= BBox.france.maxLon - BBox.france.minLon,
              maxLat - minLat <= BBox.france.maxLat - BBox.france.minLat
        else { return [] }
        let columns = max(1, Int(((maxLon - minLon) / maxSpan).rounded(.up)))
        let rows = max(1, Int(((maxLat - minLat) / maxSpan).rounded(.up)))
        guard columns <= BBox.maxSplitSide, rows <= BBox.maxSplitSide else { return [] }
        let width = (maxLon - minLon) / Double(columns)
        let height = (maxLat - minLat) / Double(rows)
        var out: [BBox] = []
        for row in 0..<rows {
            for column in 0..<columns {
                out.append(BBox(
                    minLon: minLon + Double(column) * width, minLat: minLat + Double(row) * height,
                    maxLon: column == columns - 1 ? maxLon : minLon + Double(column + 1) * width,
                    maxLat: row == rows - 1 ? maxLat : minLat + Double(row + 1) * height
                ))
            }
        }
        return out
    }

    /// Nombre maximal de colonnes ou de lignes d'un découpage (un pas minuscule sur une grande emprise).
    static let maxSplitSide = 200
}
