import Foundation

/// Statut de la forêt d'un point (étape B5, 6 nov. 2026) : la couche des forêts publiques de l'ONF,
/// servie par le WFS de la Géoplateforme de l'IGN (sans clé, champs `llib_frt` et `cdom_frt`),
/// interrogée sur un carré de quelques mètres autour du point. Mêmes phrases que le site
/// (`web/site.js` › `forestPhrase`). Rien dans le pipeline, rien sur la carte par défaut.
nonisolated enum PublicForest {
    static let host = "data.geopf.fr"
    static let layer = "ONF.FORETS_PUBLIQUES:ONF_FORETS_PUBLIQUES"
    /// Demi-côté du carré interrogé, en degrés (≈ 2 m).
    static let halfSide = 0.00002

    nonisolated struct Response: Decodable, Sendable {
        nonisolated struct Feature: Decodable, Sendable {
            let properties: Properties?
        }

        nonisolated struct Properties: Decodable, Sendable {
            /// Nom de la forêt (« Forêt domaniale de la Joux »).
            let name: String?
            /// « OUI » pour une forêt domaniale.
            let domaniale: String?

            enum CodingKeys: String, CodingKey {
                case name = "llib_frt"
                case domaniale = "cdom_frt"
            }
        }

        let features: [Feature]
    }

    /// `GetFeature` au point : BBOX en latitude puis longitude (`urn:ogc:def:crs:EPSG::4326`).
    static func url(latitude: Double, longitude: Double) -> URL? {
        let d = halfSide
        let bbox = [latitude - d, longitude - d, latitude + d, longitude + d]
            .map { String(format: "%.6f", $0) }
            .joined(separator: ",")
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/wfs/ows"
        components.queryItems = [
            URLQueryItem(name: "SERVICE", value: "WFS"),
            URLQueryItem(name: "VERSION", value: "2.0.0"),
            URLQueryItem(name: "REQUEST", value: "GetFeature"),
            URLQueryItem(name: "TYPENAMES", value: layer),
            URLQueryItem(name: "OUTPUTFORMAT", value: "application/json"),
            URLQueryItem(name: "COUNT", value: "1"),
            URLQueryItem(name: "PROPERTYNAME", value: "llib_frt,cdom_frt"),
            URLQueryItem(name: "BBOX", value: "\(bbox),urn:ogc:def:crs:EPSG::4326"),
        ]
        return components.url
    }

    /// La ligne de la fiche : forêt domaniale, autre forêt publique, ou sans doute privée.
    static func phrase(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(Response.self, from: data)
        return phrase(response.features.first?.properties)
    }

    static func phrase(_ properties: Response.Properties?) -> String {
        guard let properties else {
            return "Pas une forêt publique connue : sans doute privée, accord du propriétaire nécessaire"
        }
        let name = properties.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Forêt publique"
        return properties.domaniale == "OUI"
            ? "\(name) : forêt domaniale, cueillette familiale tolérée, sauf arrêté"
            : "\(name) : forêt publique, cueillette familiale en général tolérée, sauf arrêté"
    }
}
