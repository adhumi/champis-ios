import Foundation

/// Web Mercator XYZ, tuiles de 256 px : mêmes formules que la carte web (`tilePixelToLngLat`).
/// XYZ natif des deux côtés (PMTiles et MapKit), aucune conversion TMS.
nonisolated enum TileMath {
    static let tileSize = 256

    /// Longitude et latitude du point (`px`, `py`) de la tuile z/x/y, pixels fractionnaires.
    static func lonLat(z: Int, x: Int, y: Int, px: Double, py: Double) -> (lon: Double, lat: Double) {
        let n = Double(1 << z)
        let size = Double(tileSize)
        let lon = (Double(x) + px / size) / n * 360 - 180
        let latRad = atan(sinh(.pi * (1 - 2 * (Double(y) + py / size) / n)))
        return (lon, latRad * 180 / .pi)
    }

    /// Tuile et pixel (entiers, bornés à la tuile) contenant une coordonnée au niveau z.
    static func tile(lon: Double, lat: Double, z: Int) -> (x: Int, y: Int, px: Int, py: Int) {
        let n = Double(1 << z)
        let size = Double(tileSize)
        let fx = (lon + 180) / 360 * n
        let latRad = lat * .pi / 180
        let fy = (1 - log(tan(latRad) + 1 / cos(latRad)) / .pi) / 2 * n
        let x = Int(fx.rounded(.down))
        let y = Int(fy.rounded(.down))
        let px = Int(((fx - Double(x)) * size).rounded(.down))
        let py = Int(((fy - Double(y)) * size).rounded(.down))
        return (x, y, min(max(px, 0), tileSize - 1), min(max(py, 0), tileSize - 1))
    }
}
