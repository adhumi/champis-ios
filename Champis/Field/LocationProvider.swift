import CoreLocation
import Foundation

/// Position « pendant l'utilisation » pour une observation : la première mesure qui arrive, avec
/// un délai. Rien n'est enregistré au-delà de l'observation elle-même ; aucun trajet.
nonisolated enum LocationProvider {
    nonisolated struct Fix: Hashable, Sendable {
        let latitude: Double
        let longitude: Double
        /// Précision horizontale en mètres, `nil` si inconnue.
        let accuracyM: Double?
    }

    static func currentFix(timeout: Duration = .seconds(15)) async throws -> Fix? {
        try await withThrowingTaskGroup(of: Fix?.self) { group in
            group.addTask {
                for try await update in CLLocationUpdate.liveUpdates() {
                    if let location = update.location {
                        let accuracy = location.horizontalAccuracy
                        return Fix(
                            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                            accuracyM: accuracy >= 0 ? accuracy : nil
                        )
                    }
                    if update.authorizationDenied || update.authorizationRestricted {
                        return nil
                    }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
