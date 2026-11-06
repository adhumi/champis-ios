import Foundation
import Testing
@testable import Champis

/// Étape B5 (6 nov. 2026) : statut de la forêt d'un point par la couche ONF des forêts publiques
/// (WFS de la Géoplateforme IGN), mêmes phrases que le site.
struct PublicForestTests {
    @Test("Requête WFS : la couche ONF, un carré de quelques mètres, latitude puis longitude")
    func url() throws {
        let url = try #require(PublicForest.url(latitude: 46.9, longitude: 6.35))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "data.geopf.fr")
        #expect(components.path == "/wfs/ows")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["REQUEST"] == "GetFeature")
        #expect(items["TYPENAMES"] == "ONF.FORETS_PUBLIQUES:ONF_FORETS_PUBLIQUES")
        #expect(items["OUTPUTFORMAT"] == "application/json")
        #expect(items["COUNT"] == "1")
        #expect(items["BBOX"] == "46.899980,6.349980,46.900020,6.350020,urn:ogc:def:crs:EPSG::4326")
    }

    @Test("Phrases : domaniale, autre forêt publique, sans doute privée")
    func phrases() throws {
        let domaniale = try PublicForest.phrase(from: Data("""
        {"type": "FeatureCollection", "features": [{"type": "Feature", "geometry": null,
          "properties": {"llib_frt": "Forêt domaniale du Risoux", "cdom_frt": "OUI"}}]}
        """.utf8))
        #expect(domaniale == "Forêt domaniale du Risoux : forêt domaniale, cueillette familiale tolérée, sauf arrêté")

        let communale = try PublicForest.phrase(from: Data("""
        {"features": [{"properties": {"llib_frt": "Forêt communale de Morbier", "cdom_frt": "NON"}}]}
        """.utf8))
        #expect(communale == "Forêt communale de Morbier : forêt publique, cueillette familiale en général tolérée, sauf arrêté")

        let unnamed = try PublicForest.phrase(from: Data(#"{"features": [{"properties": {"llib_frt": "", "cdom_frt": "NON"}}]}"#.utf8))
        #expect(unnamed.hasPrefix("Forêt publique : forêt publique"))

        let none = try PublicForest.phrase(from: Data(#"{"type": "FeatureCollection", "features": []}"#.utf8))
        #expect(none == "Pas une forêt publique connue : sans doute privée, accord du propriétaire nécessaire")
    }

    @Test("Réponse illisible : une erreur, jamais « privée » par défaut")
    func unreadable() {
        #expect(throws: (any Error).self) {
            try PublicForest.phrase(from: Data("<ExceptionReport/>".utf8))
        }
    }
}
