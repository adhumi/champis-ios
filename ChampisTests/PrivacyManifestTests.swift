import Foundation
import Testing
@testable import Champis

/// Étape C (6 nov. 2026) : le manifeste de confidentialité est bien dans l'app et dit ce que disent
/// les étiquettes de l'App Store (`docs/app-store.md`) ; les réglages mènent aux bons textes.
@MainActor
struct PrivacyManifestTests {
    @Test("Manifeste : dans le paquet de l'app, sans suivi, données et raisons d'API déclarées")
    func manifest() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let plist = try #require(object as? [String: Any])
        #expect(plist["NSPrivacyTracking"] as? Bool == false)
        #expect((plist["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)

        let collected = (plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? [])
        let types = collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }
        #expect(Set(types) == [
            "NSPrivacyCollectedDataTypePreciseLocation",
            "NSPrivacyCollectedDataTypeUserID",
            "NSPrivacyCollectedDataTypeOtherUserContent",
        ])
        #expect(collected.allSatisfy { $0["NSPrivacyCollectedDataTypeTracking"] as? Bool == false })

        let apis = (plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? [])
            .compactMap { $0["NSPrivacyAccessedAPIType"] as? String }
        #expect(apis.contains("NSPrivacyAccessedAPICategoryUserDefaults"))
        #expect(apis.contains("NSPrivacyAccessedAPICategoryFileTimestamp"))
    }

    @Test("Réglages : Soutenir mène à la page du site, Confidentialité est dans le Guide")
    func settingsLinks() {
        #expect(SettingsView.supportURL.absoluteString == "https://champis.app/web/soutenir.html")
        #expect(SettingsView.contactURL.absoluteString == "mailto:hello@champis.app")
        #expect(SettingsView.legalArticles.map(\.id) == ["confidentialite", "mentions-legales"])
    }

    @Test("Accueil : l'accroche et la promesse décidées, les mêmes que le site")
    func tagline() {
        #expect(OnboardingView.tagline == "La météo des champignons, forêt par forêt.")
        #expect(OnboardingView.promise.hasSuffix("Gratuit, sans compte."))
    }
}
