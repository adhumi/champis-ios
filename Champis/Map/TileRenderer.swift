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

/// Une tuile colorisée et la génération de réglages qui l'a produite ; `image == nil` : rien à
/// dessiner (hors forêt, hors emprise, aucune couche choisie). `CGImage` est immuable : la boîte
/// peut passer d'un fil à l'autre.
nonisolated final class RenderedTile: @unchecked Sendable {
    let generation: Int
    let image: CGImage?

    init(generation: Int, image: CGImage?) {
        self.generation = generation
        self.image = image
    }
}

/// Produit l'image d'une tuile z/x/y pour l'overlay : lit `T` de chaque espèce (et `A`) dans
/// `TileStore` en parallèle, colorise. Le cache des images rendues est dans `ScoreOverlayRenderer`,
/// qui garde l'ancienne image à l'écran tant que la nouvelle n'est pas prête. Changer de jour ne
/// recharge aucune tuile de données : seule la colorisation est refaite.
nonisolated final class TileRenderer: Sendable {
    private struct State {
        var settings = RenderSettings()
        var generation = 0
    }

    let store: TileStore
    private let state = Mutex(State())

    init(store: TileStore) {
        self.store = store
    }

    /// Numéro des réglages courants : une image d'une autre génération est périmée.
    var generation: Int {
        state.withLock { $0.generation }
    }

    func update(_ settings: RenderSettings) {
        state.withLock {
            $0.settings = settings
            $0.generation += 1
        }
    }

    /// Tuile colorisée avec les réglages courants.
    func render(z: Int, x: Int, y: Int) async throws -> RenderedTile {
        let (settings, generation) = state.withLock { ($0.settings, $0.generation) }
        guard let layer = settings.layer, let colorizer = settings.colorizer else {
            return RenderedTile(generation: generation, image: nil)
        }

        // Toutes les espèces de la couche et la couche A en même temps : une requête Range chacune
        // au premier affichage, autant les lancer ensemble.
        let store = store
        let wantAlt = settings.mode == .score
        let (terrain, alt) = try await withThrowingTaskGroup(of: (String?, DecodedPNG?).self) { group in
            for sid in layer.members {
                group.addTask { (sid, try await store.terrainTile(species: sid, z: z, x: x, y: y)) }
            }
            if wantAlt {
                group.addTask { (nil, try await store.altitudeTile(z: z, x: x, y: y)) }
            }
            var terrain: [String: DecodedPNG] = [:]
            var alt: DecodedPNG?
            for try await (sid, png) in group {
                if let sid {
                    terrain[sid] = png
                } else {
                    alt = png
                }
            }
            return (terrain, alt)
        }
        let tiles = layer.members.compactMap { sid in
            terrain[sid].map { TileColorizer.SpeciesTile(species: sid, png: $0) }
        }
        guard !tiles.isEmpty else { return RenderedTile(generation: generation, image: nil) }

        let request = TileColorizer.Request(
            z: z, x: x, y: y, mode: settings.mode, date: settings.date, tiles: tiles, alt: alt,
            weather: settings.weather
        )
        let image = colorizer.render(request).flatMap { TileImage.cgImage(rgba: $0, size: TileMath.tileSize) }
        return RenderedTile(generation: generation, image: image)
    }
}

/// Images des tuiles colorisées (sortie seulement : le décodage des tuiles de données reste
/// octet par octet dans `ChampisPMTiles`, jamais via `UIImage`).
nonisolated enum TileImage {
    /// Tuile entièrement transparente, pour les zones sans donnée.
    static let empty: Data = png(rgba: [UInt8](repeating: 0, count: TileMath.tileSize * TileMath.tileSize * 4),
                                 size: TileMath.tileSize) ?? Data()

    /// Image RGBA sans interpolation (les pixels 25 m restent nets à l'agrandissement). Les octets
    /// reçus ont un alpha droit (le violet de l'échelle et l'alpha du score, `TileColorizer`) ;
    /// Core Graphics attend des couleurs prémultipliées, sinon il compose `couleur + (1 − α) × fond`
    /// avec la couleur entière : un pixel « faible » couvrait la carte d'un lavande presque opaque.
    static func cgImage(rgba: [UInt8], size: Int) -> CGImage? {
        guard rgba.count == size * size * 4 else { return nil }
        guard let provider = CGDataProvider(data: Data(premultiplied(rgba)) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let image = CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else { return nil }
        return image
    }

    /// Couleurs multipliées par l'alpha, arrondies au plus proche (`(c × a + 127) / 255`) : un alpha
    /// de 255 laisse les octets intacts, un alpha de 0 donne un pixel tout à zéro.
    static func premultiplied(_ rgba: [UInt8]) -> [UInt8] {
        var out = rgba
        var i = 0
        while i + 3 < out.count {
            let a = UInt16(out[i + 3])
            if a != 255 {
                for k in i..<(i + 3) {
                    out[k] = UInt8((UInt16(out[k]) * a + 127) / 255)
                }
            }
            i += 4
        }
        return out
    }

    static func png(rgba: [UInt8], size: Int) -> Data? {
        guard let image = cgImage(rgba: rgba, size: size) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
