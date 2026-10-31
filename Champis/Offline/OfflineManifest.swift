import Foundation

/// Un fichier PMTiles d'un département téléchargé (skill `offline`).
nonisolated struct OfflineFile: Codable, Hashable, Sendable {
    let name: String
    /// `T` (une espèce) ou `A` (classes d'altitude).
    let kind: String
    let species: String?
    let url: String
    var bytes: Int64
    var done: Bool
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
}

nonisolated extension BBox {
    /// Découpe en sous-emprises d'au plus `maxSpan` degrés de côté : `GET /weather/bbox` refuse plus
    /// de 40 cellules de 5 km, un département en compte des centaines.
    func split(maxSpan: Double) -> [BBox] {
        let columns = max(1, Int(((maxLon - minLon) / maxSpan).rounded(.up)))
        let rows = max(1, Int(((maxLat - minLat) / maxSpan).rounded(.up)))
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
}
