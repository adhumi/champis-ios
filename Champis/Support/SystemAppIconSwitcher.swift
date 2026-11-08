#if os(iOS)
import UIKit

/// Les icônes alternatives d'iOS et d'iPadOS. macOS n'en a pas : le sélecteur n'y est pas proposé.
/// Le système confirme lui-même le changement par une alerte.
struct SystemAppIconSwitcher: AppIconSwitcher {
    var supportsAlternateIcons: Bool { UIApplication.shared.supportsAlternateIcons }

    var alternateIconName: String? { UIApplication.shared.alternateIconName }

    func setAlternateIconName(_ name: String?) async throws {
        try await UIApplication.shared.setAlternateIconName(name)
    }
}
#endif
