/// Ce que le sélecteur d'icône demande au système : `SystemAppIconSwitcher` sur iOS et iPadOS, un
/// double dans les tests.
protocol AppIconSwitcher {
    var supportsAlternateIcons: Bool { get }
    /// L'icône en service ; nil pour l'icône principale.
    var alternateIconName: String? { get }
    func setAlternateIconName(_ name: String?) async throws
}
