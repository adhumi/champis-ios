import Foundation

/// Interpolation de la météo entre cellules (spec › Scoring › Interpolation de la météo entre
/// cellules, 13 nov. 2026).
///
/// La valeur d'une cellule est celle de son centre ; entre les centres, `M_eff × Φ` est interpolé
/// en bilinéaire dans la grille Lambert-93 de 5 km. Les poids sont renormalisés sur les coins qui
/// ont une valeur, et la cellule qui contient le point doit en avoir une (sinon : pas de météo).
///
/// Portage de `api/champis_api/interp.py` (champis-api), validé par `shared/vectors/interp.json`.
/// La projection est la formule directe (GRS80), la même dans les trois langages.
public enum CellInterpolation {
    /// Côté d'une cellule de la grille météo, en mètres.
    public static let cellMeters = 5000.0

    // Lambert-93 (RGF93, conique conforme sécante 44° / 49°, origine 46,5° N 3° E) : constantes IGN.
    private static let e = 0.0818191910428158  // première excentricité GRS80
    private static let n = 0.7256077650532670
    private static let c = 11754255.426096
    private static let xs = 700000.0
    private static let ys = 12655612.049876
    private static let lon0 = 3.0 * Double.pi / 180

    /// (x, y) Lambert-93 en mètres d'un point WGS84 en degrés.
    public static func lambert93(lat: Double, lon: Double) -> (x: Double, y: Double) {
        let s = sin(lat * Double.pi / 180)
        let iso = atanh(s) - e * atanh(e * s)  // latitude isométrique
        let r = c * exp(-n * iso)
        let gamma = n * (lon * Double.pi / 180 - lon0)
        return (xs + r * sin(gamma), ys - r * cos(gamma))
    }

    /// Indices d'une cellule dans la grille : son coin sud-ouest est à (5 i, 5 j) km.
    public struct GridIndex: Hashable, Sendable {
        public let i: Int
        public let j: Int

        public init(i: Int, j: Int) {
            self.i = i
            self.j = j
        }

        /// `c_0930_6680` → (186, 1336) ; `nil` si l'identifiant n'a pas cette forme.
        public init?(id: String) {
            let parts = id.split(separator: "_", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "c",
                  let xKm = Int(parts[1]), let yKm = Int(parts[2]),
                  xKm >= 0, yKm >= 0, xKm % 5 == 0, yKm % 5 == 0
            else { return nil }
            self.i = xKm / 5
            self.j = yKm / 5
        }

        /// Identifiant de la cellule : coin sud-ouest en km sur quatre chiffres (`c_0930_6680`).
        public var id: String {
            "c_\(Self.pad4(i * 5))_\(Self.pad4(j * 5))"
        }

        private static func pad4(_ value: Int) -> String {
            let digits = String(value)
            return digits.count >= 4 ? digits : String(repeating: "0", count: 4 - digits.count) + digits
        }
    }

    /// Les quatre cellules dont les centres encadrent un point, dans l'ordre SO, SE, NO, NE, avec
    /// leurs poids bilinéaires (somme 1), et la cellule qui contient le point.
    public struct Corners: Sendable {
        public let containing: GridIndex
        public let cells: [GridIndex]
        public let weights: [Double]
    }

    public static func corners(lat: Double, lon: Double) -> Corners {
        let p = lambert93(lat: lat, lon: lon)
        let u = p.x / cellMeters - 0.5  // en unités de cellule, 0 au centre de la cellule d'indice 0
        let v = p.y / cellMeters - 0.5
        let i0 = Int(u.rounded(.down))
        let j0 = Int(v.rounded(.down))
        let fx = u - Double(i0)
        let fy = v - Double(j0)
        return Corners(
            containing: GridIndex(
                i: Int((p.x / cellMeters).rounded(.down)), j: Int((p.y / cellMeters).rounded(.down))
            ),
            cells: [
                GridIndex(i: i0, j: j0),
                GridIndex(i: i0 + 1, j: j0),
                GridIndex(i: i0, j: j0 + 1),
                GridIndex(i: i0 + 1, j: j0 + 1),
            ],
            weights: [(1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy]
        )
    }

    /// Moyenne des coins qui ont une valeur, pondérée par leurs poids renormalisés ; `nil` si la
    /// cellule qui contient le point n'en a pas (ses pixels restent sans météo).
    public static func interpolate(_ corners: Corners, value: (GridIndex) -> Double?) -> Double? {
        guard value(corners.containing) != nil else { return nil }
        var num = 0.0
        var den = 0.0
        for (cell, weight) in zip(corners.cells, corners.weights) {
            if let v = value(cell) {
                num += weight * v
                den += weight
            }
        }
        return num / den
    }

    // MARK: - Entre classes d'altitude

    /// Altitude (m) au milieu de la tranche d'indice `index` de la couche E (pas `stepM`).
    public static func elevation(index: Int, stepM: Double) -> Double {
        (Double(index) + 0.5) * stepM
    }

    /// Valeur à l'altitude `altitude` d'une cellule dont `values[i]` est `M_eff × Φ` au centre
    /// `centers[i]` (croissants) : linéaire entre les deux centres qui encadrent l'altitude, à plat
    /// en dessous du premier et au-dessus du dernier ; une classe sans valeur (`nil`) est ignorée,
    /// `nil` si aucune n'en a. Portage de `interp.between_classes` (champis-api), validé par
    /// `shared/vectors/alt.json` (spec › Scoring › Interpolation entre classes d'altitude).
    public static func betweenClasses(altitude: Double, centers: [Double], values: [Double?]) -> Double? {
        var previous: (center: Double, value: Double)?
        for (center, value) in zip(centers, values) {
            guard let value else { continue }
            if altitude <= center {
                guard let previous else { return value }
                return previous.value + (altitude - previous.center) / (center - previous.center) * (value - previous.value)
            }
            previous = (center, value)
        }
        return previous?.value
    }
}
