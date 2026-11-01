import MapKit
import SwiftUI

#if os(macOS)
private typealias PlatformRepresentable = NSViewRepresentable
private typealias PlatformGestureRecognizer = NSGestureRecognizer
private typealias PlatformLongPressRecognizer = NSPressGestureRecognizer
private typealias PlatformColor = NSColor
#else
private typealias PlatformRepresentable = UIViewRepresentable
private typealias PlatformGestureRecognizer = UIGestureRecognizer
private typealias PlatformLongPressRecognizer = UILongPressGestureRecognizer
private typealias PlatformColor = UIColor
#endif

/// `MKMapView` dans SwiftUI. La `Map` SwiftUI n'accepte pas d'`MKTileOverlay` : l'overlay colorisé
/// passe par MapKit classique (décision du 30 oct. 2026, spec › App iOS). Le fond Apple reste sous
/// l'overlay, dont l'opacité est réglable. En vue France, les tuiles s'effacent et les départements
/// (polygones du GeoJSON servi par l'API) se colorent par l'indice du jour.
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
        private var tileRenderer: ScoreOverlayRenderer?
        private var shownGeneration = -1
        private var shownFranceView: Bool?
        private var shownFollowRequest = 0
        private var shownFocusRequest = 0
        private var basemap: Basemap?
        private var deptOverlaysInstalled = false
        private var deptRenderers: [String: [MKOverlayPathRenderer]] = [:]
        private var deptNames: [String: String] = [:]
        private var observationPins: [UUID: MKPointAnnotation] = [:]
        private var coinPins: [UUID: MKPointAnnotation] = [:]
        private var pinKinds: [ObjectIdentifier: PinKind] = [:]

        enum PinKind {
            case found
            case notFound
            case coin
        }

        init(model: MapModel) {
            self.model = model
        }

        func makeMapView() -> MKMapView {
            let mapView = MKMapView(frame: .zero)
            self.mapView = mapView
            mapView.delegate = self
            mapView.setRegion(MapModel.initialRegion, animated: false)
            mapView.showsUserLocation = true
            mapView.addOverlay(model.overlay, level: .aboveRoads)
            #if os(macOS)
            let recognizer = NSClickGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            #else
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            #endif
            mapView.addGestureRecognizer(recognizer)
            #if os(macOS)
            let longPress = NSPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPress.minimumPressDuration = 0.5
            #else
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPress.minimumPressDuration = 0.5
            #endif
            mapView.addGestureRecognizer(longPress)
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
            tileRenderer?.alpha = model.isFranceView ? 0 : model.overlayOpacity
            if shownFollowRequest != model.followRequest {
                shownFollowRequest = model.followRequest
                mapView.setUserTrackingMode(.follow, animated: true)
            }
            if let focus = model.focusRequest, focus.id != shownFocusRequest {
                shownFocusRequest = focus.id
                mapView.setUserTrackingMode(.none, animated: false)
                let center = CLLocationCoordinate2D(latitude: focus.latitude, longitude: focus.longitude)
                mapView.setRegion(
                    MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)),
                    animated: true
                )
            }
            if !deptOverlaysInstalled && !model.deptFeatures.isEmpty {
                installDepartements(on: mapView)
            }
            syncPins(on: mapView)
            if shownGeneration != model.renderGeneration || shownFranceView != model.isFranceView {
                shownGeneration = model.renderGeneration
                shownFranceView = model.isFranceView
                tileRenderer?.settingsChanged()
                recolorDepartements()
            }
        }

        // MARK: Départements

        private func installDepartements(on mapView: MKMapView) {
            deptOverlaysInstalled = true
            for feature in model.deptFeatures {
                guard let properties = feature.properties,
                      let dict = try? JSONSerialization.jsonObject(with: properties) as? [String: Any],
                      let code = dict["code"] as? String
                else { continue }
                deptNames[code] = dict["nom"] as? String
                for shape in feature.geometry {
                    shape.title = code
                    if let polygon = shape as? MKPolygon {
                        mapView.addOverlay(polygon, level: .aboveRoads)
                    } else if let multi = shape as? MKMultiPolygon {
                        mapView.addOverlay(multi, level: .aboveRoads)
                    }
                }
            }
        }

        private func deptRenderer(_ renderer: MKOverlayPathRenderer, code: String?) -> MKOverlayPathRenderer {
            renderer.lineWidth = 0.8
            renderer.strokeColor = PlatformColor.black.withAlphaComponent(0.35)
            style(renderer, code: code)
            if let code {
                deptRenderers[code, default: []].append(renderer)
            }
            return renderer
        }

        private func style(_ renderer: MKOverlayPathRenderer, code: String?) {
            if let code, let c = model.deptColor(code: code) {
                renderer.fillColor = PlatformColor(
                    red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 0.8
                )
            } else {
                renderer.fillColor = PlatformColor.clear
            }
            renderer.alpha = model.isFranceView ? 1 : 0
        }

        private func recolorDepartements() {
            for (code, renderers) in deptRenderers {
                for renderer in renderers {
                    style(renderer, code: code)
                    renderer.setNeedsDisplay()
                }
            }
        }

        /// Département sous une coordonnée, par le tracé des polygones déjà rendus.
        private func departement(at coordinate: CLLocationCoordinate2D) -> String? {
            let mapPoint = MKMapPoint(coordinate)
            for (code, renderers) in deptRenderers {
                for renderer in renderers where renderer.path?.contains(renderer.point(for: mapPoint)) == true {
                    return code
                }
            }
            return nil
        }

        // MARK: Épingles (mes observations, mes coins : privées, jamais celles des autres)

        private func syncPins(on mapView: MKMapView) {
            var wantedObservations: [UUID: FieldObservation] = [:]
            for observation in model.field.observations {
                wantedObservations[observation.id] = observation
            }
            for (id, pin) in observationPins where wantedObservations[id] == nil {
                mapView.removeAnnotation(pin)
                pinKinds[ObjectIdentifier(pin)] = nil
                observationPins[id] = nil
            }
            for (id, observation) in wantedObservations where observationPins[id] == nil {
                let pin = MKPointAnnotation()
                pin.coordinate = CLLocationCoordinate2D(latitude: observation.lat, longitude: observation.lon)
                pin.title = model.speciesName(observation.species)
                pin.subtitle = (observation.found ? "Trouvé · " : "Rien trouvé · ") + MapModel.format(iso: observation.date)
                pinKinds[ObjectIdentifier(pin)] = observation.found ? .found : .notFound
                observationPins[id] = pin
                mapView.addAnnotation(pin)
            }

            var wantedCoins: [UUID: Coin] = [:]
            for coin in model.field.coins {
                wantedCoins[coin.id] = coin
            }
            for (id, pin) in coinPins where wantedCoins[id] == nil {
                mapView.removeAnnotation(pin)
                pinKinds[ObjectIdentifier(pin)] = nil
                coinPins[id] = nil
            }
            for (id, coin) in wantedCoins where coinPins[id] == nil {
                let pin = MKPointAnnotation()
                pin.coordinate = CLLocationCoordinate2D(latitude: coin.lat, longitude: coin.lon)
                pin.title = coin.name
                pin.subtitle = model.layerTitle(forTarget: coin.target)
                pinKinds[ObjectIdentifier(pin)] = .coin
                coinPins[id] = pin
                mapView.addAnnotation(pin)
            }
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard let point = annotation as? MKPointAnnotation, let kind = pinKinds[ObjectIdentifier(point)] else {
                return nil  // position de l'utilisateur et tout le reste : vue par défaut
            }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "pin") as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: point, reuseIdentifier: "pin")
            view.annotation = point
            view.canShowCallout = true
            switch kind {
            case .found:
                view.markerTintColor = PlatformColor.systemGreen
                view.glyphText = "✓"
            case .notFound:
                view.markerTintColor = PlatformColor.systemGray
                view.glyphText = "✗"
            case .coin:
                view.markerTintColor = PlatformColor.systemOrange
                view.glyphText = "★"
            }
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? ScoreTileOverlay {
                let renderer = ScoreOverlayRenderer(overlay: tiles)
                renderer.alpha = model.isFranceView ? 0 : model.overlayOpacity
                tileRenderer = renderer
                return renderer
            }
            if let polygon = overlay as? MKPolygon {
                return deptRenderer(MKPolygonRenderer(polygon: polygon), code: polygon.title)
            }
            if let multi = overlay as? MKMultiPolygon {
                return deptRenderer(MKMultiPolygonRenderer(multiPolygon: multi), code: multi.title)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            model.visibleRegionChanged(Self.bbox(of: mapView), zoom: Self.zoomLevel(of: mapView))
        }

        @objc private func handleTap(_ gesture: PlatformGestureRecognizer) {
            guard let mapView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            if model.isFranceView {
                let code = departement(at: coordinate)
                model.selectDepartement(code: code, name: code.flatMap { deptNames[$0] })
            } else {
                model.select(latitude: coordinate.latitude, longitude: coordinate.longitude)
            }
        }

        /// Appui long (lot 3) : le menu de terrain au point pressé, sans passer par la fiche.
        @objc private func handleLongPress(_ gesture: PlatformLongPressRecognizer) {
            guard gesture.state == .began, let mapView, !model.isFranceView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            model.longPress(latitude: coordinate.latitude, longitude: coordinate.longitude)
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

        /// Niveau de zoom Web Mercator approximatif de la vue (tuiles de 256 points).
        static func zoomLevel(of mapView: MKMapView) -> Double {
            let width = Double(mapView.bounds.width)
            let lonDelta = mapView.region.span.longitudeDelta
            guard width > 0, lonDelta > 0 else { return 0 }
            return log2(360 * width / 256 / lonDelta)
        }
    }
}
