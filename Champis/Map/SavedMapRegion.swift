import Foundation

/// Dernière région vue de la carte (décision du 16 nov. 2026) : son centre et son étendue, rien
/// d'autre, gardés sur l'appareil dans `UserDefaults` à la fin d'un déplacement et repris au
/// lancement suivant. Au premier lancement, ou si la valeur gardée n'est pas valide, la carte
/// s'ouvre sur la France métropolitaine entière, Corse comprise. Ce n'est pas la position de
/// l'utilisateur : rien n'est lu du GPS, aucune permission n'est demandée, rien ne part au serveur.
nonisolated struct SavedMapRegion: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let latitudeDelta: Double
    let longitudeDelta: Double

    /// Clé de `UserDefaults` : quatre nombres, `[latitude, longitude, latitudeDelta, longitudeDelta]`.
    static let defaultsKey = "mapLastRegion"

    /// France métropolitaine et Corse : d'Ouessant (−5,2°) à la côte est de la Corse (9,6°), de
    /// Bonifacio (41,3°) à Dunkerque (51,1°). La carte ajuste l'étendue aux proportions de l'écran.
    static let france = SavedMapRegion(
        uncheckedLatitude: 46.2, longitude: 2.2, latitudeDelta: 10.4, longitudeDelta: 15.2
    )

    /// Étendue la plus petite gardée, en degrés (une cinquantaine de mètres).
    static let minDelta = 0.0005
    static let maxLatitude = 85.0
    static let maxLatitudeDelta = 90.0
    static let maxLongitudeDelta = 180.0

    /// `nil` si un nombre n'est pas fini ou sort des bornes : un centre hors du globe ou trop près
    /// d'un pôle, une étendue nulle, négative ou plus grande qu'un demi-globe.
    init?(latitude: Double, longitude: Double, latitudeDelta: Double, longitudeDelta: Double) {
        guard latitude.isFinite, longitude.isFinite, latitudeDelta.isFinite, longitudeDelta.isFinite else { return nil }
        guard abs(latitude) <= SavedMapRegion.maxLatitude, abs(longitude) <= 180 else { return nil }
        guard latitudeDelta >= SavedMapRegion.minDelta, latitudeDelta <= SavedMapRegion.maxLatitudeDelta else { return nil }
        guard longitudeDelta >= SavedMapRegion.minDelta, longitudeDelta <= SavedMapRegion.maxLongitudeDelta else { return nil }
        guard abs(latitude) + latitudeDelta / 2 <= 90 else { return nil }
        self.latitude = latitude
        self.longitude = longitude
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }

    private init(uncheckedLatitude latitude: Double, longitude: Double, latitudeDelta: Double, longitudeDelta: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }

    /// Lecture de la valeur gardée : exactement quatre nombres valides, sinon `nil`.
    init?(stored: [Double]?) {
        guard let stored, stored.count == 4 else { return nil }
        self.init(latitude: stored[0], longitude: stored[1], latitudeDelta: stored[2], longitudeDelta: stored[3])
    }

    /// La valeur à garder.
    var stored: [Double] {
        [latitude, longitude, latitudeDelta, longitudeDelta]
    }

    /// Région d'ouverture de la carte : la dernière vue si elle est valide, sinon la France.
    static func initial(stored: [Double]?) -> SavedMapRegion {
        SavedMapRegion(stored: stored) ?? france
    }

    /// Ce que `UserDefaults` garde sous `defaultsKey` ; `nil` si rien, ou autre chose que des nombres.
    static func storedValue(in defaults: UserDefaults) -> [Double]? {
        defaults.array(forKey: defaultsKey) as? [Double]
    }

    func save(in defaults: UserDefaults) {
        defaults.set(stored, forKey: SavedMapRegion.defaultsKey)
    }
}
