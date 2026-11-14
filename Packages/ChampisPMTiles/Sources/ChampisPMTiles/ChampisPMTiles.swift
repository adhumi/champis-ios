/// Lecteur PMTiles v3 maison et décodeur PNG de données, sans dépendance (spec › App iOS,
/// décision du 16 oct. 2026 ; skills `offline` et `swiftui-mapkit`).
///
/// - `PMTilesReader` lit un fichier PMTiles local (`LocalFileSource`) ou distant par requêtes
///   `Range` (`RemoteRangeSource`) : en-tête, répertoires racine et feuilles, identifiant de tuile
///   par courbe de Hilbert, données par plage d'octets.
/// - `PNGDecoder` lit les octets d'un PNG de données (T × 254, classes d'altitude) : jamais via
///   `UIImage`/`CGImage`, dont la gestion des couleurs décale les gris d'un niveau et change la
///   classe d'un pixel près des seuils (même leçon que `web/png.js`).
///
/// Un fichier malformé (téléchargement tronqué, serveur compromis, cache abîmé) lève une erreur du
/// paquet, il n'arrête jamais l'app : les tailles lues dans le fichier sont converties sans
/// débordement et plafonnées avant toute lecture ou allocation (audit du 13 nov. 2026).
public enum ChampisPMTiles {
    public static let specVersion: UInt8 = 3
    /// Plafond d'un répertoire (racine ou feuille) et des métadonnées, compressés comme décompressés.
    public static let maxDirectoryBytes = 16 << 20
    /// Plafond d'une tuile telle qu'elle est rangée dans le fichier.
    public static let maxTileBytes = 1 << 20
    /// Plafond d'une tuile une fois décompressée (fichiers dont les tuiles sont en gzip).
    public static let maxTileDecompressedBytes = 4 << 20
    /// Zoom maximal adressable : au-delà, l'identifiant de Hilbert dépasse 64 bits.
    public static let maxZoom = 31
}

public enum PMTilesError: Error, Equatable, Sendable {
    case notPMTiles
    case unsupportedVersion(UInt8)
    case truncated(String)
    case unsupportedCompression(UInt8)
    case rangeUnavailable(Int)  // code HTTP inattendu
    case corruptDirectory(String)
    /// Flux DEFLATE invalide ou interrompu (répertoire, métadonnées ou tuile).
    case corruptData(String)
    /// Taille annoncée par le fichier, ou produite par la décompression, au-delà du plafond.
    case tooLarge(String)
}

public enum PNGError: Error, Equatable, Sendable {
    case badSignature
    case truncatedChunk(String)
    case missingHeader
    case unsupported(String)
    case badFilter(UInt8, row: Int)
    case shortData(expected: Int, got: Int)
    /// Flux zlib invalide, interrompu, ou plus long que l'image annoncée par l'en-tête.
    case corrupt(String)
}
