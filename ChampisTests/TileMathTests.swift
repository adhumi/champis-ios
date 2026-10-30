import Testing
@testable import Champis

struct TileMathTests {
    @Test("Coins et centre d'une tuile en Web Mercator")
    func lonLat() {
        let corner = TileMath.lonLat(z: 0, x: 0, y: 0, px: 0, py: 0)
        #expect(abs(corner.lon + 180) < 1e-9)
        #expect(abs(corner.lat - 85.0511287798) < 1e-6)
        let origin = TileMath.lonLat(z: 1, x: 1, y: 1, px: 0, py: 0)
        #expect(abs(origin.lon) < 1e-9 && abs(origin.lat) < 1e-9)
        let center = TileMath.lonLat(z: 6, x: 33, y: 22, px: 128, py: 128)
        #expect(abs(center.lon - 8.4375) < 1e-9)
        #expect(abs(center.lat - 47.04) < 0.01)
    }

    @Test("Coordonnée → tuile et pixel, aller-retour")
    func tile() {
        let t = TileMath.tile(lon: 8.4375, lat: 47.04, z: 6)
        #expect(t.x == 33 && t.y == 22)
        #expect(t.px == 128)
        #expect((127...128).contains(t.py))
        let back = TileMath.lonLat(z: 6, x: t.x, y: t.y, px: Double(t.px) + 0.5, py: Double(t.py) + 0.5)
        #expect(abs(back.lon - 8.4375) < 0.03)
        #expect(abs(back.lat - 47.04) < 0.03)
        let edge = TileMath.tile(lon: 179.99999, lat: -85, z: 2)
        #expect(edge.x == 3 && edge.y == 3)
        #expect(edge.px <= 255 && edge.py <= 255)
    }
}
