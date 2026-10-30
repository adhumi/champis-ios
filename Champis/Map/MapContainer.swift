import MapKit
import SwiftUI

#if os(macOS)
private typealias PlatformRepresentable = NSViewRepresentable
private typealias PlatformGestureRecognizer = NSGestureRecognizer
#else
private typealias PlatformRepresentable = UIViewRepresentable
private typealias PlatformGestureRecognizer = UIGestureRecognizer
#endif

/// `MKMapView` dans SwiftUI. La `Map` SwiftUI n'accepte pas d'`MKTileOverlay` : l'overlay colorisé
/// passe par MapKit classique (décision du 30 oct. 2026, spec › App iOS). Le fond Apple reste sous
/// l'overlay, dont l'opacité est réglable.
struct MapContainer: PlatformRepresentable {
    let model: MapModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    #if os(macOS)
    func makeNSView(context: Context) -> MKMapView {
        context.coordinator.makeMapView()
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.update(mapView)
    }
    #else
    func makeUIView(context: Context) -> MKMapView {
        context.coordinator.makeMapView()
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.update(mapView)
    }
    #endif

    final class Coordinator: NSObject, MKMapViewDelegate {
        let model: MapModel
        private weak var mapView: MKMapView?
        private var tileRenderer: MKTileOverlayRenderer?
        private var shownGeneration = -1
        private var basemap: Basemap?

        init(model: MapModel) {
            self.model = model
        }

        func makeMapView() -> MKMapView {
            let mapView = MKMapView(frame: .zero)
            self.mapView = mapView
            mapView.delegate = self
            mapView.setRegion(MapModel.initialRegion, animated: false)
            mapView.addOverlay(model.overlay, level: .aboveRoads)
            #if os(macOS)
            let recognizer = NSClickGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            #else
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            #endif
            mapView.addGestureRecognizer(recognizer)
            return mapView
        }

        func update(_ mapView: MKMapView) {
            if basemap != model.basemap {
                basemap = model.basemap
                switch model.basemap {
                case .standard:
                    mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
                case .satellite:
                    mapView.preferredConfiguration = MKImageryMapConfiguration()
                }
            }
            tileRenderer?.alpha = model.overlayOpacity
            if shownGeneration != model.renderGeneration {
                shownGeneration = model.renderGeneration
                tileRenderer?.reloadData()
            }
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tiles)
                renderer.alpha = model.overlayOpacity
                tileRenderer = renderer
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            model.visibleRegionChanged(Self.bbox(of: mapView))
        }

        @objc private func handleTap(_ gesture: PlatformGestureRecognizer) {
            guard let mapView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            model.select(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }

        /// Emprise visible en degrés (coins sud-ouest et nord-est de la vue).
        static func bbox(of mapView: MKMapView) -> BBox {
            let rect = mapView.visibleMapRect
            let southWest = MKMapPoint(x: rect.minX, y: rect.maxY).coordinate
            let northEast = MKMapPoint(x: rect.maxX, y: rect.minY).coordinate
            return BBox(
                minLon: southWest.longitude, minLat: southWest.latitude,
                maxLon: northEast.longitude, maxLat: northEast.latitude
            )
        }
    }
}
