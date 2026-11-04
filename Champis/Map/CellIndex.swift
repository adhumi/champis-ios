import Foundation

/// Index spatial des cellules météo : casiers de 0,05° (≈ 5,5 km × 3,9 km, à peu près une cellule
/// de la grille de 5 km), pour trouver la cellule la plus proche d'un point sans parcourir les
/// 20 000 cellules du champ France entière à chaque bloc de 16 px. Fonction pure, `Sendable`,
/// reconstruite à chaque fusion de `WeatherField`.
///
/// Au-delà de `maxDistanceKm` de la cellule la plus proche (une cellule et demie, comme la carte
/// web), le point n'a pas de météo : transparent, plutôt que la météo d'une cellule chargée pour
/// une autre emprise (étude du 4 nov. 2026). Une cellule sans donnée pour (espèce, jour, classe)
/// ne cède jamais la place à sa voisine : l'index ne renvoie que la plus proche, et c'est au
/// coloriste de la laisser transparente.
nonisolated struct CellIndex: Sendable {
    nonisolated struct Entry: Hashable, Sendable {
        let id: String
        let lat: Double
        let lon: Double
    }

    static let binDegrees = 0.05
    static let maxDistanceKm = 7.5
    static let kmPerDegree = 111.2

    private let entries: [Entry]
    /// Clé de casier → indices dans `entries`.
    private let bins: [Int: [Int]]

    init() {
        entries = []
        bins = [:]
    }

    init(_ cells: [Entry]) {
        entries = cells
        var bins: [Int: [Int]] = [:]
        bins.reserveCapacity(cells.count)
        for (i, c) in cells.enumerated() {
            bins[Self.binKey(lat: c.lat, lon: c.lon), default: []].append(i)
        }
        self.bins = bins
    }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    /// Casier d'une coordonnée : (rangée, colonne) de 0,05°.
    static func bin(lat: Double, lon: Double) -> (row: Int, col: Int) {
        (Int((lat / binDegrees).rounded(.down)), Int((lon / binDegrees).rounded(.down)))
    }

    static func binKey(row: Int, col: Int) -> Int {
        // 100 000 colonnes de 0,05° font bien plus qu'un tour de Terre : pas de collision.
        row &* 100_000 &+ col
    }

    static func binKey(lat: Double, lon: Double) -> Int {
        let b = bin(lat: lat, lon: lon)
        return binKey(row: b.row, col: b.col)
    }

    /// Cellule la plus proche à moins de `maxDistanceKm` (distance équirectangulaire, comme la
    /// carte web), ou `nil`. Ne visite que les casiers qui couvrent ce rayon autour du point :
    /// quelques dizaines de candidats, quel que soit le nombre de cellules.
    func nearest(lat: Double, lon: Double, maxDistanceKm: Double = CellIndex.maxDistanceKm) -> Entry? {
        guard !entries.isEmpty else { return nil }
        let k = cos(lat * .pi / 180)
        let radiusDeg = maxDistanceKm / Self.kmPerDegree
        var bestDistance = radiusDeg * radiusDeg
        var best: Entry?
        // Rayon en longitude dilaté par 1 / cos(lat) ; une latitude polaire donnerait une division
        // par zéro, on borne.
        let radiusLon = radiusDeg / max(k, 0.01)
        let low = Self.bin(lat: lat - radiusDeg, lon: lon - radiusLon)
        let high = Self.bin(lat: lat + radiusDeg, lon: lon + radiusLon)
        for row in low.row...high.row {
            for col in low.col...high.col {
                guard let indices = bins[Self.binKey(row: row, col: col)] else { continue }
                for i in indices {
                    let c = entries[i]
                    let dLat = c.lat - lat
                    let dLon = (c.lon - lon) * k
                    let d = dLat * dLat + dLon * dLon
                    if d < bestDistance {
                        bestDistance = d
                        best = c
                    }
                }
            }
        }
        return best
    }
}
