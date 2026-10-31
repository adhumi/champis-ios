import ChampisPMTiles
import ChampisScoring
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// Ce qu'il faut savoir pour coloriser une tuile à un instant donné : une copie `Sendable` poussée
/// par `MapModel` à chaque changement (espèce, jour, mode, météo reçue).
nonisolated struct RenderSettings: Sendable {
    var layer: Layer?
    var mode: MapMode = .score
    var date: String?
    var weather = WeatherField()
    var colorizer: TileColorizer?
}

/// Produit l'image PNG d'une tuile z/x/y pour l'overlay : lit `T` (et `A`) dans `TileStore`,
/// colorise, encode. Cache des PNG rendus, vidé à chaque changement de réglages. Changer de jour ne
/// recharge aucune tuile de données : seule la colorisation est refaite.
nonisolated final class TileRenderer: Sendable {
    private struct Key: Hashable {
        let z: Int
        let x: Int
        let y: Int
    }

    private struct State {
        var settings = RenderSettings()
        var rendered: [Key: Data] = [:]
        var generation = 0
    }

    static let maxRendered = 256

    let store: TileStore
    private let state = Mutex(State())

    init(store: TileStore) {
        self.store = store
    }

    func update(_ settings: RenderSettings) {
        state.withLock {
            $0.settings = settings
            $0.rendered.removeAll(keepingCapacity: true)
            $0.generation += 1
        }
    }

    /// PNG RGBA de la tuile ; `nil` s'il n'y a rien à dessiner (hors emprise, aucune couche choisie).
    func pngData(z: Int, x: Int, y: Int) async throws -> Data? {
        let key = Key(z: z, x: x, y: y)
        let (settings, generation, hit) = state.withLock { ($0.settings, $0.generation, $0.rendered[key]) }
        if let hit { return hit }
        guard let layer = settings.layer, let colorizer = settings.colorizer else { return nil }

        var tiles: [TileColorizer.SpeciesTile] = []
        for sid in layer.members {
            if let png = try await store.terrainTile(species: sid, z: z, x: x, y: y) {
                tiles.append(TileColorizer.SpeciesTile(species: sid, png: png))
            }
        }
        guard !tiles.isEmpty else { return nil }
        var alt: DecodedPNG?
        if settings.mode == .score {
            alt = try await store.altitudeTile(z: z, x: x, y: y)
        }

        let request = TileColorizer.Request(
            z: z, x: x, y: y, mode: settings.mode, date: settings.date, tiles: tiles, alt: alt,
            weather: settings.weather
        )
        guard let rgba = colorizer.render(request), let png = TileImage.png(rgba: rgba, size: TileMath.tileSize) else {
            return nil
        }
        state.withLock {
            // Réglages changés pendant le rendu : l'image ne correspond plus, ne pas la garder.
            guard $0.generation == generation else { return }
            if $0.rendered.count >= Self.maxRendered {
                $0.rendered.removeAll(keepingCapacity: true)
            }
            $0.rendered[key] = png
        }
        return png
    }
}

/// Encodage PNG des tuiles colorisées (sortie seulement : le décodage des tuiles de données reste
/// octet par octet dans `ChampisPMTiles`, jamais via `UIImage`).
nonisolated enum TileImage {
    /// Tuile entièrement transparente, pour les zones sans donnée.
    static let empty: Data = png(rgba: [UInt8](repeating: 0, count: TileMath.tileSize * TileMath.tileSize * 4),
                                 size: TileMath.tileSize) ?? Data()

    static func png(rgba: [UInt8], size: Int) -> Data? {
        guard rgba.count == size * size * 4 else { return nil }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        // Les pixels transparents sont noirs : les octets valent déjà comme prémultipliés.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let image = CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
