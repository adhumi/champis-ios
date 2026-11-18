import ChampisPMTiles
import ChampisScoring
import Foundation
import Testing
@testable import Champis

/// Fiche d'un point, toutes les espèces et une phrase (spec › App iOS, 17 nov. 2026).
struct PointSpeciesTests {
    static func catalog() throws -> SpeciesCatalog {
        try Fixtures.decode(SpeciesCatalog.self, Fixtures.catalogJSON)
    }

    /// `GET /weather?cell=` pour deux espèces, avec `sentence` sur la girolle seulement.
    static let detailJSON = """
    {
      "cell": { "id": "c_1", "lat": 47.04, "lon": 8.44, "alt_classes": [450], "elevation_m": 500 },
      "stale": false,
      "species": {
        "cantharellus_cibarius": [
          { "date": "2026-10-30", "by_alt": { "450": {
            "M": 0.8, "M_eff": 0.8, "phi": 0.5, "factors": { "temp": 1.0 }, "trigger_days": 22,
            "summary": ["grosse pluie il y a 22 jours : la pousse s'essouffle", "fin de saison"],
            "sentence": "la dernière grosse pluie remonte à 22 jours et la pousse s'essouffle ; la saison touche à sa fin",
            "sentence_tone": "defavorable"
          } } }
        ],
        "boletus_aereus": [
          { "date": "2026-10-30", "by_alt": { "450": { "M": 0.2, "M_eff": 0.2, "phi": 1.0, "summary": ["pleine saison"] } } }
        ]
      }
    }
    """

    @Test("La phrase : terrain, deux-points, sentence de l'API et un point ; repli sur summary")
    func sentence() {
        let full = PointSheet.sentence(
            terrain: "excellent", mode: .score, sentence: "le sol est bien humide, mais il a gelé ces dernières nuits", summary: ["sol bien humide"]
        )
        #expect(full.sentence == "Terrain très favorable : le sol est bien humide, mais il a gelé ces dernières nuits.")
        #expect(full.phrases.isEmpty)
        let old = PointSheet.sentence(terrain: "bon", mode: .score, sentence: nil, summary: ["sol sec", "fin de saison"])
        #expect(old.sentence == "Terrain favorable.")
        #expect(old.phrases == ["sol sec", "fin de saison"])
        let loading = PointSheet.sentence(terrain: "moyen", mode: .score, sentence: nil, summary: nil)
        #expect(loading.sentence == "Terrain moyen." && loading.phrases.isEmpty)
        let terrain = PointSheet.sentence(terrain: "faible", mode: .terrain, sentence: "ignorée", tone: "favorable", summary: nil)
        #expect(terrain.sentence == "Terrain peu favorable : potentiel toute saison, sans la météo.")
    }

    @Test("Liaison : « et » dans le même sens que le terrain, « mais » à l'opposé, virgule si neutre")
    func link() {
        let late = "la dernière grosse pluie remonte à 23 jours et la pousse s'essouffle"
        let but = PointSheet.sentence(terrain: "excellent", mode: .score, sentence: late, tone: "defavorable", summary: nil)
        #expect(but.sentence == "Terrain très favorable mais \(late).")
        #expect(PointSheet.link(terrain: "bon", tone: "favorable") == " et ")
        #expect(PointSheet.link(terrain: "faible", tone: "defavorable") == " et ")
        #expect(PointSheet.link(terrain: "tres_faible", tone: "favorable") == " mais ")
        #expect(PointSheet.link(terrain: "bon", tone: "neutre") == ", ")
        #expect(PointSheet.link(terrain: "moyen", tone: "defavorable") == ", ")
        #expect(PointSheet.link(terrain: nil, tone: "favorable") == ", ")
        // réponse plus ancienne, sans sentence_tone : les deux-points d'avant
        #expect(PointSheet.link(terrain: "bon", tone: nil) == " : ")
    }

    @Test("GET /weather : sentence se décode, et manque sans erreur d'une API plus ancienne")
    func decodesSentence() throws {
        let detail = try Fixtures.decode(CellWeather.self, Self.detailJSON)
        let girolle = try #require(detail.species["cantharellus_cibarius"]?.first?.byAlt["450"])
        #expect(girolle.sentence?.hasPrefix("la dernière grosse pluie remonte à 22 jours") == true)
        let aereus = try #require(detail.species["boletus_aereus"]?.first?.byAlt["450"])
        #expect(girolle.sentenceTone == "defavorable")
        #expect(aereus.sentence == nil && aereus.sentenceTone == nil && aereus.summary == ["pleine saison"])
    }

    @Test("Valeurs : la couche garde celle de la carte, les autres T × M_eff × Φ de la cellule")
    func values() throws {
        let detail = try Fixtures.decode(CellWeather.self, Self.detailJSON)
        var info = PointInfo(latitude: 47.04, longitude: 8.44, mode: .score, date: "2026-10-30", outcome: .noData)
        info.terrains = ["boletus_edulis": 1.0, "boletus_aereus": 0.5, "cantharellus_cibarius": 0.5]
        info.layerValues = ["boletus_edulis": 0.9]
        info.altKey = "450"
        // -1 : pas de score
        let values = { (detail: CellWeather?) in
            Dictionary(uniqueKeysWithValues: PointFamilies.species(info: info, detail: detail).map { ($0.id, $0.value ?? -1) })
        }
        let before = values(nil)
        #expect(before["boletus_edulis"] == 0.9)
        #expect(before["boletus_aereus"] == -1)
        let after = values(detail)
        #expect(after["boletus_edulis"] == 0.9)
        #expect(abs((after["boletus_aereus"] ?? 0) - 0.1) < 1e-9)
        #expect(abs((after["cantharellus_cibarius"] ?? 0) - 0.2) < 1e-9)

        var terrain = PointInfo(latitude: 47.04, longitude: 8.44, mode: .terrain, date: nil, outcome: .noData)
        terrain.terrains = ["cantharellus_cibarius": 0.5]
        #expect(PointFamilies.species(info: terrain, detail: nil) == [PointSpecies(id: "cantharellus_cibarius", terrain: 0.5, value: 0.5)])
    }

    @Test("Familles : celle de l'espèce mise en avant d'abord, puis par score ; l'espèce en avant n'y est pas")
    func families() throws {
        let catalog = try Self.catalog()
        let species = [
            PointSpecies(id: "boletus_edulis", terrain: 1.0, value: 0.3),
            PointSpecies(id: "boletus_aereus", terrain: 0.5, value: 0.1),
            PointSpecies(id: "cantharellus_cibarius", terrain: 0.5, value: 0.8),
        ]
        let lead = PointFamilies.families(species, catalog: catalog, featured: "boletus_edulis")
        #expect(lead.map(\.id) == ["cepes", "girolles"])
        #expect(lead[0].title == "Cèpes" && lead[0].species.map(\.id) == ["boletus_aereus"])
        #expect(lead[1].species.map(\.id) == ["cantharellus_cibarius"])

        // la girolle mise en avant : sa famille n'a plus personne, les cèpes restent, par score
        let other = PointFamilies.families(species, catalog: catalog, featured: "cantharellus_cibarius")
        #expect(other.map(\.id) == ["cepes"])
        #expect(other[0].species.map(\.id) == ["boletus_edulis", "boletus_aereus"])

        // rien en avant (la couche n'a pas de terrain ici) : par meilleur score ; sans score en dernier
        let none = PointFamilies.families(
            [species[1], PointSpecies(id: "boletus_edulis", terrain: 1.0, value: nil), species[2]], catalog: catalog, featured: nil
        )
        #expect(none.map(\.id) == ["girolles", "cepes"])
        #expect(none[1].species.map(\.id) == ["boletus_aereus", "boletus_edulis"])
    }

    @Test("Inspecteur : le terrain de toutes les espèces du catalogue au pixel, T nul et tuile absente écartés")
    func inspectsCatalog() async throws {
        let size = PointInspectorTests.size
        let t = TileMath.tile(lon: PointInspectorTests.longitude, lat: PointInspectorTests.latitude, z: PointInspector.zoom)
        let i = t.py * size + t.px
        func reader(_ value: UInt8) throws -> PMTilesReader {
            let png = try PointInspectorTests.tile([(i, value)])
            return PMTilesReader(source: MemorySource(data: PointInspectorTests.pmtiles(tiles: [(t.x, t.y, png)])))
        }
        let store = TileStore()
        await store.install(
            terrain: ["boletus_edulis": try reader(254), "cantharellus_cibarius": try reader(127), "boletus_aereus": try reader(0)],
            alt: try reader(1)
        )
        let info = try await PointInspector.inspect(
            latitude: PointInspectorTests.latitude, longitude: PointInspectorTests.longitude,
            settings: try PointInspectorTests.settings(mode: .score, weather: try PointInspectorTests.weather()), store: store,
            catalogSpecies: ["boletus_edulis", "boletus_aereus", "cantharellus_cibarius", "morchella_esculenta"]
        )
        #expect(info.scored?.species == "boletus_edulis")
        #expect(Set(info.terrains.keys) == ["boletus_edulis", "cantharellus_cibarius"])
        #expect(abs((info.terrains["cantharellus_cibarius"] ?? 0) - 0.5) < 1e-9)
        #expect(abs((info.layerValues["boletus_edulis"] ?? 0) - 0.9) < 1e-9)
        #expect(info.layerValues["cantharellus_cibarius"] == nil)
        #expect(info.cell?.id == "c_1" && info.altKey == "450" && info.altClass == 1)
        // un coin ne garde toujours que les espèces de la couche
        #expect(info.scored?.terrains.keys.sorted() == ["boletus_edulis"])
    }

    @Test("Ligne dépliée : la phrase de l'espèce et sa tendance ; rien tant que la météo manque")
    func expansion() throws {
        let detail = try Fixtures.decode(CellWeather.self, Self.detailJSON)
        var info = PointInfo(latitude: 47.04, longitude: 8.44, mode: .score, date: "2026-10-30", outcome: .noData)
        info.terrains = ["cantharellus_cibarius": 0.5, "boletus_aereus": 0.5]
        info.altKey = "450"
        let girolle = PointSpecies(id: "cantharellus_cibarius", terrain: 0.5, value: 0.2)
        let open = try #require(PointFamilies.expansion(
            species: girolle, info: info, detail: detail, terrainLabel: "bon", today: "2026-10-30", goodMin: 0.5
        ))
        #expect(open.sentence == "Terrain favorable mais la dernière grosse pluie remonte à 22 jours et la pousse s'essouffle ; la saison touche à sa fin.")
        #expect(open.phrases.isEmpty)
        // un seul jour connu : pas de tendance à dire
        #expect(open.trend == nil)
        // API plus ancienne : le terrain, puis la liste d'avant
        let aereus = PointSpecies(id: "boletus_aereus", terrain: 0.5, value: 0.1)
        let old = try #require(PointFamilies.expansion(
            species: aereus, info: info, detail: detail, terrainLabel: "moyen", today: "2026-10-30", goodMin: 0.5
        ))
        #expect(old.sentence == "Terrain moyen." && old.phrases == ["pleine saison"])
        // la météo du point n'est pas arrivée
        #expect(PointFamilies.expansion(species: girolle, info: info, detail: nil, terrainLabel: "bon", today: nil, goodMin: nil) == nil)
        var terrain = PointInfo(latitude: 47.04, longitude: 8.44, mode: .terrain, date: nil, outcome: .noData)
        terrain.terrains = ["cantharellus_cibarius": 0.5]
        let potential = PointFamilies.expansion(species: girolle, info: terrain, detail: nil, terrainLabel: "bon", today: nil, goodMin: nil)
        #expect(potential?.sentence == "Terrain favorable : potentiel toute saison, sans la météo.")
    }

    @Test("Inspecteur sans couche (fiche d'un coin) : le terrain du catalogue, aucune espèce en exergue")
    func inspectsWithoutLayer() async throws {
        let store = try await PointInspectorTests.store(altClass: 1)
        let settings = RenderSettings(
            layer: nil, mode: .score, date: "2026-10-30", weather: try PointInspectorTests.weather(),
            colorizer: TileColorizer(palette: try PointInspectorTests.palette())
        )
        let info = try await PointInspector.inspect(
            latitude: PointInspectorTests.latitude, longitude: PointInspectorTests.longitude, settings: settings, store: store,
            catalogSpecies: ["boletus_edulis", "cantharellus_cibarius"]
        )
        #expect(info.scored == nil && info.isNoData)
        #expect(info.terrains == ["boletus_edulis": 1.0])
        #expect(info.layerValues.isEmpty)
        #expect(info.cell?.id == "c_1" && info.altKey == "450")
        // sans couche ni catalogue : rien à lire
        let nothing = try await PointInspector.inspect(
            latitude: PointInspectorTests.latitude, longitude: PointInspectorTests.longitude, settings: settings, store: store
        )
        #expect(nothing.terrains.isEmpty && nothing.isNoData)
    }

    @Test("Toucher sur l'épingle d'un coin : autour du ballon, pas plus loin")
    func pinHit() {
        let anchor = CGPoint(x: 100, y: 200)
        #expect(MapContainer.Coordinator.hitsPin(tap: CGPoint(x: 104, y: 170), anchor: anchor))
        #expect(MapContainer.Coordinator.hitsPin(tap: anchor, anchor: anchor))
        #expect(!MapContainer.Coordinator.hitsPin(tap: CGPoint(x: 140, y: 190), anchor: anchor))
        #expect(!MapContainer.Coordinator.hitsPin(tap: CGPoint(x: 100, y: 120), anchor: anchor))
    }
}
