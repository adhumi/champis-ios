import Foundation
import MapKit
import Synchronization

/// Overlay des tuiles colorisées : XYZ natif, 256 px, niveaux 6–15, sans remplacer le fond Apple.
/// Il ne sert que de support (emprise, niveaux) : le dessin est fait par `ScoreOverlayRenderer`, pas
/// par `MKTileOverlayRenderer`.
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
}

/// Dessin de l'overlay, à la place de `MKTileOverlayRenderer` qui posait deux problèmes :
///
/// - `reloadData()` effaçait toutes les tuiles à chaque réglage (météo reçue après chaque
///   déplacement, jour, espèce) : la carte se vidait puis se remplissait carré par carré, et une
///   tuile en échec restait vide jusqu'au réglage suivant ;
/// - à un zoom non entier, les tuiles redimensionnées et lissées laissaient des coutures (liseré,
///   pixels pâles) entre elles.
///
/// Ici, une image périmée reste à l'écran jusqu'à ce que la nouvelle soit prête ; une tuile pas
/// encore rendue montre l'agrandissement d'une tuile parente déjà en cache ; une tuile en échec est
/// redemandée après un délai. Chaque image est posée sur des bords alignés au pixel, sans
/// interpolation ni anticrénelage : les tuiles voisines se touchent exactement.
///
/// MapKit appelle `draw` sur plusieurs fils à la fois : tout l'état est derrière un `Mutex`.
nonisolated final class ScoreOverlayRenderer: MKOverlayRenderer, @unchecked Sendable {
    private struct Key: Hashable {
        let z: Int
        let x: Int
        let y: Int

        var parent: Key {
            Key(z: z - 1, x: x >> 1, y: y >> 1)
        }
    }

    private struct Entry {
        let tile: RenderedTile
        var lastUse: UInt64
    }

    private struct State {
        var entries: [Key: Entry] = [:]
        var pending: Set<Key> = []
        var retryAfter: [Key: ContinuousClock.Instant] = [:]
        var clock: UInt64 = 0
    }

    /// Images gardées (256 × 256 RGBA, 256 Kio chacune) : quelques écrans d'iPad, parents compris.
    static let capacity = 192
    /// Niveaux parents essayés en attendant le rendu d'une tuile (zoom avant).
    static let ancestorLevels = 3
    static let retryDelay = 3.0  // secondes

    private let tiles: TileRenderer
    private let minZ: Int
    private let maxZ: Int
    private let state = Mutex(State())

    init(overlay: ScoreTileOverlay) {
        tiles = overlay.renderer
        minZ = overlay.minimumZ
        maxZ = overlay.maximumZ
        super.init(overlay: overlay)
    }

    /// Réglages poussés au rendu : tout est redessiné, les anciennes images restent affichées
    /// jusqu'à leur remplacement.
    func settingsChanged() {
        setNeedsDisplay()
    }

    /// Niveau de tuile dont un pixel fait environ un point d'écran à cette échelle
    /// (`zoomScale` = points d'écran par point de carte ; le monde fait 256 × 2^z points au niveau z).
    static func tileZoom(zoomScale: MKZoomScale) -> Int {
        let z = log2(Double(zoomScale) * MKMapSize.world.width / Double(TileMath.tileSize))
        return z.isFinite ? Int(z.rounded()) : 0
    }

    private static func mapRect(_ key: Key) -> MKMapRect {
        let span = MKMapSize.world.width / Double(1 << key.z)
        return MKMapRect(x: Double(key.x) * span, y: Double(key.y) * span, width: span, height: span)
    }

    override func canDraw(_ mapRect: MKMapRect, zoomScale: MKZoomScale) -> Bool {
        true  // on dessine ce qu'on a ; le reste arrive par setNeedsDisplay
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let wanted = Self.tileZoom(zoomScale: zoomScale)
        guard wanted >= minZ else { return }
        let z = min(wanted, maxZ)  // au-delà de 15 : la tuile 15 agrandie
        let n = 1 << z
        let span = MKMapSize.world.width / Double(n)
        let x0 = max(0, Int((mapRect.minX / span).rounded(.down)))
        let x1 = min(n - 1, Int((mapRect.maxX / span).rounded(.up)) - 1)
        let y0 = max(0, Int((mapRect.minY / span).rounded(.down)))
        let y1 = min(n - 1, Int((mapRect.maxY / span).rounded(.up)) - 1)
        guard x0 <= x1, y0 <= y1 else { return }
        let generation = tiles.generation

        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect(for: mapRect))
        context.interpolationQuality = .none
        context.setShouldAntialias(false)

        for y in y0...y1 {
            for x in x0...x1 {
                let key = Key(z: z, x: x, y: y)
                let (own, placeholder) = lookup(key)
                if own?.generation != generation {
                    request(key)
                }
                if let own {
                    if let image = own.image {
                        paint(image, at: Self.mapRect(key), clippedTo: nil, in: context)
                    }
                } else if let placeholder, let image = placeholder.tile.image {
                    paint(image, at: Self.mapRect(placeholder.key), clippedTo: Self.mapRect(key), in: context)
                }
            }
        }
    }

    /// L'image de la tuile (même périmée) ; à défaut, la plus proche tuile parente qui a une image.
    private func lookup(_ key: Key) -> (own: RenderedTile?, placeholder: (key: Key, tile: RenderedTile)?) {
        state.withLock { s in
            s.clock += 1
            if var entry = s.entries[key] {
                entry.lastUse = s.clock
                s.entries[key] = entry
                return (entry.tile, nil)
            }
            var ancestor = key
            for _ in 0..<Self.ancestorLevels where ancestor.z > minZ {
                ancestor = ancestor.parent
                if let tile = s.entries[ancestor]?.tile, tile.image != nil {
                    return (nil, (ancestor, tile))
                }
            }
            return (nil, nil)
        }
    }

    /// Lance le rendu de la tuile, une seule fois à la fois, pas avant la fin du délai après un échec.
    private func request(_ key: Key) {
        let start = state.withLock { s -> Bool in
            if s.pending.contains(key) { return false }
            if let retry = s.retryAfter[key], ContinuousClock.now < retry { return false }
            s.pending.insert(key)
            return true
        }
        guard start else { return }
        let tiles = tiles
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let rendered = try await tiles.render(z: key.z, x: key.x, y: key.y)
                self?.store(rendered, for: key)
            } catch {
                self?.failed(key)
            }
        }
    }

    private func store(_ tile: RenderedTile, for key: Key) {
        state.withLock { s in
            s.pending.remove(key)
            s.retryAfter[key] = nil
            if let current = s.entries[key], current.tile.generation > tile.generation { return }
            s.clock += 1
            s.entries[key] = Entry(tile: tile, lastUse: s.clock)
            if s.entries.count > Self.capacity {
                // Les moins récemment dessinées partent, par quart pour ne pas trier à chaque tuile.
                let excess = s.entries.count - Self.capacity * 3 / 4
                let victims = s.entries.sorted { $0.value.lastUse < $1.value.lastUse }.prefix(excess)
                for (old, _) in victims {
                    s.entries[old] = nil
                }
            }
        }
        invalidate(key, after: 0)
    }

    private func failed(_ key: Key) {
        state.withLock { s in
            s.pending.remove(key)
            s.retryAfter[key] = ContinuousClock.now + .seconds(Self.retryDelay)
        }
        invalidate(key, after: Self.retryDelay)
    }

    /// Redessine la zone de la tuile (toutes échelles : elle sert aussi de parente) sur le fil principal.
    private func invalidate(_ key: Key, after seconds: Double) {
        let rect = Self.mapRect(key)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.setNeedsDisplay(rect)
        }
    }

    /// Pose l'image sur le rectangle de carte, bords arrondis au pixel de l'écran. L'espace de
    /// dessin de MapKit a l'axe y vers le bas : l'image est retournée.
    private func paint(_ image: CGImage, at tileRect: MKMapRect, clippedTo clip: MKMapRect?, in context: CGContext) {
        let target = Self.snapped(rect(for: tileRect), in: context)
        context.saveGState()
        if let clip {
            context.clip(to: Self.snapped(rect(for: clip), in: context))
        }
        context.translateBy(x: target.minX, y: target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: target.size))
        context.restoreGState()
    }

    /// Le rectangle dont les bords tombent sur des pixels entiers de l'écran. Deux tuiles voisines
    /// partagent un bord : arrondi de la même façon, il ne laisse ni vide ni recouvrement.
    static func snapped(_ rect: CGRect, in context: CGContext) -> CGRect {
        let device = context.convertToDeviceSpace(rect)
        let minX = device.minX.rounded()
        let minY = device.minY.rounded()
        let maxX = device.maxX.rounded()
        let maxY = device.maxY.rounded()
        guard maxX > minX, maxY > minY else { return rect }
        return context.convertToUserSpace(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }
}
