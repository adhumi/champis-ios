import Foundation
import MapKit

/// Overlay de tuiles colorisées : XYZ natif, 256 px, niveaux 6–15, sans remplacer le fond Apple.
/// MapKit appelle `loadTile` sur ses propres files : le rendu se fait hors du MainActor.
nonisolated final class ScoreTileOverlay: MKTileOverlay {
    let renderer: TileRenderer

    init(renderer: TileRenderer) {
        self.renderer = renderer
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        minimumZ = 6
        maximumZ = 15
        tileSize = CGSize(width: 256, height: 256)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        let (z, x, y) = (path.z, path.x, path.y)
        let renderer = renderer
        Task.detached(priority: .userInitiated) {
            do {
                let png = try await renderer.pngData(z: z, x: x, y: y)
                result(png ?? TileImage.empty, nil)
            } catch {
                result(nil, error)
            }
        }
    }
}
