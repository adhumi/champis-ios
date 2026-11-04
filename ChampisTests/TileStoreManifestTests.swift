import Foundation
import Testing
@testable import Champis

/// Choix des fichiers PMTiles à lire en ligne d'après le manifeste `GET /tiles` (`TileStore.chooseEntries`).
struct TileStoreManifestTests {
    static func entry(
        kind: String, name: String, species: String? = nil, scoring: String? = "1.0.0", dept: String? = nil
    ) -> TilesManifest.Entry {
        TilesManifest.Entry(
            kind: kind, name: name, url: "/tiles/" + name, bytes: 1, species: species, hash: "fe88e376",
            scoringVersion: scoring, deptsHash: nil, classM: kind == "A" ? 300 : nil, dept: dept
        )
    }

    @Test("Le jeu complet (sans dept) passe avant un jeu par département, même si ce dernier vient après par nom")
    func fullSetBeatsDepartmentSets() {
        let tiles = [
            Self.entry(kind: "T", name: "T-boletus_edulis-fe88e376-p1.0.0-d7bb9d4.pmtiles", species: "boletus_edulis"),
            Self.entry(kind: "T", name: "T-boletus_edulis-fe88e376-p1.0.0-dff5a1a.pmtiles", species: "boletus_edulis", dept: "70"),
            Self.entry(kind: "T", name: "T-boletus_edulis-fe88e376-p1.0.0-db7a568.pmtiles", species: "boletus_edulis", dept: "25"),
            Self.entry(kind: "A", name: "A-300m-d7bb9d4.pmtiles"),
            Self.entry(kind: "A", name: "A-300m-dff5a1a.pmtiles", dept: "70"),
        ]
        let chosen = TileStore.chooseEntries(tiles, scoringVersion: "1.0.0")
        #expect(chosen.terrain["boletus_edulis"]?.name == "T-boletus_edulis-fe88e376-p1.0.0-d7bb9d4.pmtiles")
        #expect(chosen.alt?.name == "A-300m-d7bb9d4.pmtiles")
    }

    @Test("Version de scoring de l'app préférée ; à défaut, le dernier nom ; les entrées inconnues ignorées")
    func scoringVersionThenName() {
        let tiles = [
            Self.entry(kind: "T", name: "T-cantharellus_cibarius-9e6a9da6-p1.1.0-d7bb9d4.pmtiles", species: "cantharellus_cibarius", scoring: "1.1.0"),
            Self.entry(kind: "T", name: "T-cantharellus_cibarius-9e6a9da6-p1.0.0-d7bb9d4.pmtiles", species: "cantharellus_cibarius"),
            Self.entry(kind: "T", name: "T-boletus_edulis-aaaaaaaa-p1.0.0-d111111.pmtiles", species: "boletus_edulis"),
            Self.entry(kind: "T", name: "T-boletus_edulis-bbbbbbbb-p1.0.0-d222222.pmtiles", species: "boletus_edulis"),
            Self.entry(kind: "T", name: "T-sans-espece.pmtiles"),
            Self.entry(kind: "X", name: "X-inconnu.pmtiles", species: "boletus_edulis"),
        ]
        let chosen = TileStore.chooseEntries(tiles, scoringVersion: "1.0.0")
        #expect(chosen.terrain["cantharellus_cibarius"]?.name == "T-cantharellus_cibarius-9e6a9da6-p1.0.0-d7bb9d4.pmtiles")
        #expect(chosen.terrain["boletus_edulis"]?.name == "T-boletus_edulis-bbbbbbbb-p1.0.0-d222222.pmtiles")
        #expect(chosen.terrain.count == 2)
        #expect(chosen.alt == nil)
    }

    @Test("Sans jeu complet (manifeste d'un seul département), le jeu par département est lu")
    func departmentOnlyManifest() {
        let tiles = [
            Self.entry(kind: "T", name: "T-boletus_edulis-fe88e376-p1.0.0-db7a568.pmtiles", species: "boletus_edulis", dept: "25"),
            Self.entry(kind: "A", name: "A-300m-db7a568.pmtiles", dept: "25"),
        ]
        let chosen = TileStore.chooseEntries(tiles, scoringVersion: "1.0.0")
        #expect(chosen.terrain["boletus_edulis"]?.dept == "25")
        #expect(chosen.alt?.dept == "25")
    }
}
