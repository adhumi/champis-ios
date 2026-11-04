import Foundation
import Testing
@testable import Champis

struct DeptIndexTests {
    static let cepes = Layer(key: .group("cepes"), title: "Cèpes", members: ["boletus_aereus", "boletus_edulis"])
    static let aereus = Layer(key: .species("boletus_aereus"), title: "Cèpe bronzé", members: ["boletus_aereus"])

    @Test("GET /departements (bandeau des jours) : indice par groupe (max, leading) et par espèce ; jour sans météo → nil")
    func index() throws {
        let response = try Fixtures.decode(DepartementsResponse.self, Fixtures.departementsJSON)
        #expect(response.today == "2026-10-30")
        #expect(response.computedAt == "2026-10-30T03:12:00+00:00")
        #expect(response.departements.count == 2)

        let groups = DeptIndex(response: response, layer: Self.cepes)
        #expect(groups.layerKey == .group("cepes"))
        #expect(Set(groups.codes) == ["25", "39"])
        #expect(groups.value(code: "25", date: "2026-10-30") == 0.62)
        #expect(groups.row(code: "25", date: "2026-10-30")?.leading == "boletus_edulis")
        #expect(groups.row(code: "25", date: "2026-10-30")?.coverage == 0.9)
        #expect(groups.value(code: "25", date: "2026-10-31") == nil)
        #expect(groups.row(code: "25", date: "2026-10-31") != nil)
        #expect(groups.value(code: "39", date: "2026-10-30") == 0.2)
        #expect(groups.value(code: "75", date: "2026-10-30") == nil)
        #expect(groups.value(code: "25", date: "2026-12-25") == nil)

        let species = DeptIndex(response: response, layer: Self.aereus)
        #expect(species.value(code: "25", date: "2026-10-30") == 0.3)
        #expect(species.row(code: "25", date: "2026-10-30")?.leading == nil)
        #expect(species.value(code: "39", date: "2026-10-30") == nil)  // l'espèce n'y est pas servie
    }

    @Test("Horodatage de calcul lisible")
    @MainActor
    func timestamp() {
        #expect(MapModel.format(timestamp: "2026-10-30T03:12:00+00:00") != "2026-10-30T03:12:00+00:00")
        #expect(MapModel.format(timestamp: "pas une date") == "pas une date")
    }
}
