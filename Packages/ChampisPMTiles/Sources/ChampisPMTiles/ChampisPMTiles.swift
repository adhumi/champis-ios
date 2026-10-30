/// Lecteur PMTiles v3 maison et décodeur PNG de données, sans dépendance (spec › App iOS,
/// décision du 16 oct. 2026 ; skills `offline` et `swiftui-mapkit`).
///
/// - `PMTilesReader` lit un fichier PMTiles local (`LocalFileSource`) ou distant par requêtes
///   `Range` (`RemoteRangeSource`) : en-tête, répertoires racine et feuilles, identifiant de tuile
///   par courbe de Hilbert, données par plage d'octets.
/// - `PNGDecoder` lit les octets d'un PNG de données (T × 254, classes d'altitude) : jamais via
///   `UIImage`/`CGImage`, dont la gestion des couleurs décale les gris d'un niveau et change la
///   classe d'un pixel près des seuils (même leçon que `web/png.js`).
public enum ChampisPMTiles {
    public static let specVersion: UInt8 = 3
}

public enum PMTilesError: Error, Equatable, Sendable {
    case notPMTiles
    case unsupportedVersion(UInt8)
    case truncated(String)
    case unsupportedCompression(UInt8)
    case rangeUnavailable(Int)  // code HTTP inattendu
    case corruptDirectory(String)
}

public enum PNGError: Error, Equatable, Sendable {
    case badSignature
    case truncatedChunk(String)
    case missingHeader
    case unsupported(String)
    case badFilter(UInt8, row: Int)
    case shortData(expected: Int, got: Int)
}
