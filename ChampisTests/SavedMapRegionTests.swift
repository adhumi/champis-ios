import Foundation
import Testing
@testable import Champis

/// Dernière région vue de la carte (décision du 16 nov. 2026) : validation et sérialisation.
struct SavedMapRegionTests {
    @Test("Premier lancement : rien de gardé, la carte s'ouvre sur la France entière, Corse comprise")
    func firstLaunch() {
        let region = SavedMapRegion.initial(stored: nil)
        #expect(region == SavedMapRegion.france)
        let south = region.latitude - region.latitudeDelta / 2
        let north = region.latitude + region.latitudeDelta / 2
        let west = region.longitude - region.longitudeDelta / 2
        let east = region.longitude + region.longitudeDelta / 2
        #expect(south <= 41.33)  // Bonifacio
        #expect(north >= 51.09)  // Dunkerque
        #expect(west <= -5.15)  // Ouessant
        #expect(east >= 9.57)  // côte est de la Corse
        #expect(SavedMapRegion(stored: SavedMapRegion.france.stored) == SavedMapRegion.france)
    }

    @Test("Aller-retour : centre et étendue, quatre nombres, rien d'autre")
    func roundTrip() throws {
        let region = try #require(SavedMapRegion(latitude: 46.71, longitude: 6.19, latitudeDelta: 0.08, longitudeDelta: 0.05))
        #expect(region.stored == [46.71, 6.19, 0.08, 0.05])
        #expect(SavedMapRegion(stored: region.stored) == region)
        #expect(SavedMapRegion.initial(stored: region.stored) == region)
    }

    static let invalidStored: [[Double]] = [
        [],
        [46.7, 6.2, 0.1],
        [46.7, 6.2, 0.1, 0.1, 0.1],
        [Double.nan, 6.2, 0.1, 0.1],
        [46.7, Double.infinity, 0.1, 0.1],
        [46.7, 6.2, -Double.infinity, 0.1],
        [46.7, 6.2, 0.1, Double.nan],
        [91, 6.2, 0.1, 0.1],
        [-86, 6.2, 0.1, 0.1],
        [46.7, 181, 0.1, 0.1],
        [46.7, -200, 0.1, 0.1],
        [46.7, 6.2, 0, 0.1],
        [46.7, 6.2, 0.1, 0],
        [46.7, 6.2, -1, 0.1],
        [46.7, 6.2, 0.1, -1],
        [46.7, 6.2, 120, 0.1],
        [46.7, 6.2, 0.1, 300],
        [80, 6.2, 30, 0.1],
    ]

    @Test("Valeur gardée non valide : ignorée, la carte s'ouvre sur la France", arguments: invalidStored)
    func invalid(stored: [Double]) {
        #expect(SavedMapRegion(stored: stored) == nil)
        #expect(SavedMapRegion.initial(stored: stored) == SavedMapRegion.france)
    }

    @Test("Bornes : comprises")
    func bounds() {
        #expect(SavedMapRegion(latitude: 85, longitude: 180, latitudeDelta: 10, longitudeDelta: 180) != nil)
        #expect(SavedMapRegion(latitude: -85, longitude: -180, latitudeDelta: 0.0005, longitudeDelta: 0.0005) != nil)
        #expect(SavedMapRegion(latitude: 0, longitude: 0, latitudeDelta: 90, longitudeDelta: 180) != nil)
        #expect(SavedMapRegion(latitude: 0, longitude: 0, latitudeDelta: 0.0004, longitudeDelta: 0.1) == nil)
    }

    @Test("UserDefaults : une seule clé ; autre chose que quatre nombres se lit comme rien")
    func defaults() throws {
        let suite = "SavedMapRegionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SavedMapRegion.defaultsKey == "mapLastRegion")
        #expect(SavedMapRegion.storedValue(in: defaults) == nil)

        let region = try #require(SavedMapRegion(latitude: 44.1, longitude: 3.6, latitudeDelta: 0.5, longitudeDelta: 0.4))
        region.save(in: defaults)
        #expect(SavedMapRegion.initial(stored: SavedMapRegion.storedValue(in: defaults)) == region)

        defaults.set("ici", forKey: SavedMapRegion.defaultsKey)
        #expect(SavedMapRegion.initial(stored: SavedMapRegion.storedValue(in: defaults)) == SavedMapRegion.france)
        defaults.set(["46.7", "6.2", "0.1", "0.1"], forKey: SavedMapRegion.defaultsKey)
        #expect(SavedMapRegion.initial(stored: SavedMapRegion.storedValue(in: defaults)) == SavedMapRegion.france)
    }
}
