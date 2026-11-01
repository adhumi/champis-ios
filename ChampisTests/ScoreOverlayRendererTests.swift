import CoreGraphics
import Foundation
import MapKit
import Testing
@testable import Champis

struct ScoreOverlayRendererTests {
    @Test("Niveau de tuile : un pixel de tuile fait environ un point d'écran")
    func tileZoom() {
        for z in [6, 10, 15, 17] {
            let scale = MKZoomScale(256 * Double(1 << z) / MKMapSize.world.width)
            #expect(ScoreOverlayRenderer.tileZoom(zoomScale: scale) == z)
            #expect(ScoreOverlayRenderer.tileZoom(zoomScale: scale * 1.3) == z)
            #expect(ScoreOverlayRenderer.tileZoom(zoomScale: scale * 0.8) == z)
        }
    }

    @Test("Bords alignés au pixel : deux tuiles voisines se touchent sans vide ni recouvrement")
    func snapped() throws {
        let context = try #require(CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: 3, y: 3)  // écran @3x
        context.translateBy(x: 0.123, y: 0.456)  // zoom non entier : bords entre deux pixels
        let left = ScoreOverlayRenderer.snapped(CGRect(x: 1.1, y: 2.2, width: 7.77, height: 7.77), in: context)
        let right = ScoreOverlayRenderer.snapped(CGRect(x: 8.87, y: 2.2, width: 7.77, height: 7.77), in: context)
        #expect(abs(left.maxX - right.minX) < 1e-9)
        let device = context.convertToDeviceSpace(left)
        for edge in [device.minX, device.maxX, device.minY, device.maxY] {
            #expect(abs(edge - edge.rounded()) < 1e-9)
        }
    }

    @Test("Rendu : image et génération des réglages ; tuile sans donnée vide")
    func render() async throws {
        let store = try await PointInspectorTests.store(altClass: 1)
        let renderer = TileRenderer(store: store)
        let empty = try await renderer.render(z: 15, x: 0, y: 0)
        #expect(empty.image == nil && empty.generation == 0)

        renderer.update(try PointInspectorTests.settings(mode: .terrain, weather: WeatherField()))
        let t = TileMath.tile(lon: PointInspectorTests.longitude, lat: PointInspectorTests.latitude, z: 15)
        let tile = try await renderer.render(z: 15, x: t.x, y: t.y)
        #expect(tile.generation == 1)
        let image = try #require(tile.image)
        #expect(image.width == TileMath.tileSize && image.height == TileMath.tileSize)
        let outside = try await renderer.render(z: 15, x: t.x + 1, y: t.y)
        #expect(outside.image == nil)
    }
}
