import Foundation
import Testing
@testable import Champis

/// Index spatial des cellules météo : voisin le plus proche, borne de 7,5 km, cellule hors casier.
struct CellIndexTests {
    static func entry(_ id: String, _ lat: Double, _ lon: Double) -> CellIndex.Entry {
        CellIndex.Entry(id: id, lat: lat, lon: lon)
    }

    @Test("Casiers de 0,05° : une coordonnée tombe dans le casier attendu, clés distinctes")
    func bins() {
        #expect(CellIndex.binDegrees == 0.05)
        let b = CellIndex.bin(lat: 47.03, lon: 8.41)
        #expect(b.row == 940 && b.col == 168)
        #expect(CellIndex.bin(lat: -0.01, lon: -0.01) == (row: -1, col: -1))
        #expect(CellIndex.binKey(row: 1, col: 2) != CellIndex.binKey(row: 2, col: 1))
        #expect(CellIndex.binKey(lat: 47.03, lon: 8.41) == CellIndex.binKey(row: 940, col: 168))
    }

    @Test("Voisin le plus proche parmi plusieurs cellules, même hors du casier du point")
    func nearest() throws {
        // grille de 5 km (0,045° en latitude, 0,066° en longitude à 47 N)
        var cells: [CellIndex.Entry] = []
        for i in 0..<5 {
            for j in 0..<5 {
                cells.append(Self.entry("c_\(i)_\(j)", 47.0 + Double(i) * 0.045, 8.4 + Double(j) * 0.066))
            }
        }
        let index = CellIndex(cells)
        #expect(index.count == 25 && !index.isEmpty)
        #expect(index.nearest(lat: 47.0, lon: 8.4)?.id == "c_0_0")
        #expect(index.nearest(lat: 47.092, lon: 8.53)?.id == "c_2_2")
        // au bord d'un casier : la cellule voisine est dans le casier d'à côté
        #expect(index.nearest(lat: 47.0499, lon: 8.4499)?.id == "c_1_1")
        #expect(index.nearest(lat: 47.0501, lon: 8.4501)?.id == "c_1_1")
        // entre deux cellules : la plus proche, pas la première trouvée
        #expect(index.nearest(lat: 47.0, lon: 8.44)?.id == "c_0_1")
        #expect(index.nearest(lat: 47.0, lon: 8.42)?.id == "c_0_0")
        // tout point d'une grille de 5 km est à moins de 7,5 km d'une cellule
        let far = try #require(index.nearest(lat: 47.02, lon: 8.43))
        #expect(far.id == "c_0_0" || far.id == "c_1_0" || far.id == "c_0_1" || far.id == "c_1_1")
    }

    @Test("Borne de 7,5 km : au-delà, nil, jamais une cellule lointaine ; borne réglable")
    func bound() {
        let index = CellIndex([Self.entry("c", 47.0, 8.4)])
        #expect(index.nearest(lat: 47.0, lon: 8.4)?.id == "c")
        // 7 km au nord : dedans ; 8 km : dehors
        #expect(index.nearest(lat: 47.0 + 7.0 / CellIndex.kmPerDegree, lon: 8.4)?.id == "c")
        #expect(index.nearest(lat: 47.0 + 8.0 / CellIndex.kmPerDegree, lon: 8.4) == nil)
        // en longitude, la distance se contracte avec cos(lat) : 0,1° à 47 N ≈ 7,6 km, dehors ; 0,09° ≈ 6,8 km, dedans
        #expect(index.nearest(lat: 47.0, lon: 8.5) == nil)
        #expect(index.nearest(lat: 47.0, lon: 8.49)?.id == "c")
        // borne plus large : la même cellule revient
        #expect(index.nearest(lat: 47.0, lon: 8.5, maxDistanceKm: 10)?.id == "c")
        #expect(index.nearest(lat: 47.0, lon: 8.5, maxDistanceKm: 5) == nil)
        #expect(CellIndex().nearest(lat: 47, lon: 8.4) == nil)
    }

    @Test("Cellule hors de tout casier visité : un point loin de tout reste sans météo")
    func outsideBins() {
        let index = CellIndex([Self.entry("a", 47.0, 8.4), Self.entry("b", 44.8, 1.51)])
        #expect(index.nearest(lat: 45.9, lon: 5.0) == nil)
        #expect(index.nearest(lat: 44.81, lon: 1.5)?.id == "b")
        #expect(index.nearest(lat: 0, lon: 0) == nil)
        // deux cellules dans le même casier : la plus proche des deux
        let twin = CellIndex([Self.entry("a", 47.01, 8.41), Self.entry("b", 47.03, 8.43)])
        #expect(twin.nearest(lat: 47.025, lon: 8.425)?.id == "b")
        #expect(twin.nearest(lat: 47.015, lon: 8.415)?.id == "a")
    }
}
