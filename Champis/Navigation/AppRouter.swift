import Foundation
import Observation
import UserNotifications

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Navigation entre les onglets et ouverture d'un coin depuis une notification (lot 1).
/// Une seule instance : le délégué d'application, hors SwiftUI, doit pouvoir la joindre.
@Observable
final class AppRouter {
    enum Tab: Hashable {
        case coins
        case map
        case understand
    }

    static let shared = AppRouter()

    /// L'app s'ouvre toujours sur la carte (décision du 1er nov. 2026).
    var tab: Tab = .map
    /// Coin à ouvrir dans Mes coins ; `CoinsScreen` le consomme puis le remet à `nil`.
    var coinToOpen: UUID?

    func open(coinID: UUID) {
        coinToOpen = coinID
        tab = .coins
    }

    /// `coin_id` de la charge utile APNs (`champis_api.coins.notify_all`).
    nonisolated static func coinID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard let raw = userInfo["coin_id"] as? String else { return nil }
        return UUID(uuidString: raw)
    }
}

/// Délégué d'application : reçoit les notifications « mes coins » et route vers la fiche du coin.
/// L'enregistrement du jeton APNs (`PUT /coins` › `apns_token`) arrive avec les clés d'Adrien.
#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let coinID = AppRouter.coinID(from: response.notification.request.content.userInfo)
        if let coinID {
            Task { @MainActor in AppRouter.shared.open(coinID: coinID) }
        }
        completionHandler()
    }
}
#elseif os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let coinID = AppRouter.coinID(from: response.notification.request.content.userInfo)
        if let coinID {
            Task { @MainActor in AppRouter.shared.open(coinID: coinID) }
        }
        completionHandler()
    }
}
#endif
