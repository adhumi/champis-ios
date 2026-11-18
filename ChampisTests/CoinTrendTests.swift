import Foundation
import Testing
@testable import Champis

struct CoinTrendTests {
    static let today = "2026-11-01"  // un dimanche

    static func days(_ values: [Double?]) -> [CoinDay] {
        // onze jours J−3 → J+7 autour du 1er nov. 2026
        let dates = ["2026-10-29", "2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02", "2026-11-03",
                     "2026-11-04", "2026-11-05", "2026-11-06", "2026-11-07", "2026-11-08"]
        return zip(dates, values).map { CoinDay(date: $0, value: $1, leading: $1 == nil ? nil : "boletus_edulis") }
    }

    @Test("Tendance : mieux tel jour seulement si un jour à venir passe « bon », sinon stable ou en baisse")
    func kind() {
        let goodMin = 0.55
        let better = Self.days([0.2, 0.3, 0.3, 0.3, 0.4, 0.5, 0.7, 0.6, 0.3, 0.2, 0.2])
        #expect(CoinTrend.kind(days: better, today: Self.today, goodMin: goodMin) == .better(day: "2026-11-04"))
        // le jour et son numéro (étape A) : « mieux mercredi » seul était ambigu à une semaine près
        #expect(CoinTrend.phrase(.better(day: "2026-11-04")) == "mieux mercredi 4")

        // meilleur jour à venir sous « bon » : pas une raison d'y aller
        let underGood = Self.days([0.2, 0.3, 0.3, 0.3, 0.4, 0.5, 0.5, 0.4, 0.3, 0.2, 0.2])
        #expect(CoinTrend.kind(days: underGood, today: Self.today, goodMin: goodMin) == .stable)

        let flat = Self.days(Array(repeating: 0.6, count: 11))
        #expect(CoinTrend.kind(days: flat, today: Self.today, goodMin: goodMin) == .stable)
        #expect(CoinTrend.phrase(.stable) == "stable toute la semaine")

        let falling = Self.days([0.8, 0.8, 0.7, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.2, 0.1])
        #expect(CoinTrend.kind(days: falling, today: Self.today, goodMin: goodMin) == .falling)
        #expect(CoinTrend.phrase(.falling) == "en baisse")

        // aujourd'hui sans météo, ou aucun jour après : inconnu, pas de phrase
        var missing = Self.days(Array(repeating: 0.6, count: 11))
        missing[3] = CoinDay(date: Self.today, value: nil, leading: nil)
        #expect(CoinTrend.kind(days: missing, today: Self.today, goodMin: goodMin) == .unknown)
        #expect(CoinTrend.kind(days: [], today: Self.today, goodMin: goodMin) == .unknown)
        #expect(CoinTrend.phrase(.unknown) == nil)
        // un jour à venir bon mais à peine mieux qu'aujourd'hui : stable
        let barely = Self.days([0.6, 0.6, 0.6, 0.6, 0.62, 0.63, 0.6, 0.6, 0.6, 0.6, 0.6])
        #expect(CoinTrend.kind(days: barely, today: Self.today, goodMin: goodMin) == .stable)
    }

    @Test("Jours en français, sans dépendre de la locale : 2026-11-01 est un dimanche")
    func frenchDays() {
        #expect(CoinTrend.weekdayName(iso: "2026-11-01") == "dimanche")
        #expect(CoinTrend.weekdayName(iso: "2026-11-02") == "lundi")
        #expect(CoinTrend.weekdayName(iso: "2026-10-31") == "samedi")
        #expect(CoinTrend.shortDay(iso: "2026-11-07") == "sam. 7")
        #expect(CoinTrend.initial(iso: "2026-11-05") == "j")
        // sous chaque pastille, le jour abrégé et son numéro (étape A, 6 nov. 2026)
        #expect(CoinTrend.shortWeekday(iso: "2026-11-07") == "sam.")
        #expect(CoinTrend.shortWeekday(iso: "2026-11-03") == "mar.")
        #expect(CoinTrend.dayOfMonth(iso: "2026-11-07") == 7)
        #expect(CoinTrend.dayOfMonth(iso: "2026-11-10") == 10)
        #expect(CoinTrend.dayOfMonth(iso: "illisible") == 0)
        #expect(CoinTrend.weekdayIndex(iso: "n'importe quoi") == 0)
    }

    @Test("Classement : du meilleur au moins bon, sans météo en dernier, puis par nom")
    func order() {
        let a = Coin(name: "Combe", lat: 47, lon: 6, target: "cepes", altClass: 450, t: ["boletus_edulis": 1])
        let b = Coin(name: "Hêtraie", lat: 47, lon: 6, target: "cepes", altClass: 450, t: ["boletus_edulis": 1])
        let c = Coin(name: "Tourbière", lat: 47, lon: 6, target: "girolles", altClass: 450, t: ["cantharellus_cibarius": 1])
        let d = Coin(name: "Aulnaie", lat: 47, lon: 6, target: "cepes", altClass: 450, t: ["boletus_edulis": 1])
        func scored(_ coin: Coin, _ value: Double?) -> ScoredCoin {
            ScoredCoin(id: coin.id, name: coin.name, score: value, leading: nil, bestDay: nil, best: nil, days: [])
        }
        let scores = [a.id: scored(a, 0.3), b.id: scored(b, 0.8), c.id: scored(c, nil), d.id: scored(d, 0.3)]
        let names = CoinTrend.order([a, b, c, d], scores: scores).map(\.name)
        #expect(names == ["Hêtraie", "Aulnaie", "Combe", "Tourbière"])
        #expect(CoinTrend.order([c, a], scores: [:]).map(\.name) == ["Combe", "Tourbière"])
    }

    @Test("Routeur : coin_id de la charge utile APNs ; une notification bascule sur Mes coins")
    @MainActor
    func router() {
        #expect(AppRouter.coinID(from: ["coin_id": "11111111-1111-1111-1111-111111111111"]) != nil)
        #expect(AppRouter.coinID(from: ["coin_id": "pas-un-uuid"]) == nil)
        #expect(AppRouter.coinID(from: [:]) == nil)
        let router = AppRouter()
        #expect(router.tab == .map)  // l'app s'ouvre toujours sur la carte
        let id = UUID()
        router.open(coinID: id)
        #expect(router.tab == .coins && router.coinToOpen == id)
    }

    @Test("Ligne d'un coin : les espèces qui valent au moins « moyen », sinon aucune n'est nommée")
    func worthSpecies() throws {
        let id = UUID()
        let json = """
        { "id": "\(id.uuidString)", "name": "Combe", "score": 0.6, "leading": "craterellus_cornucopioides",
          "best_day": null, "best": null, "days": [],
          "species": [ { "id": "craterellus_cornucopioides", "value": 0.6 }, { "id": "boletus_edulis", "value": 0.35 },
                       { "id": "boletus_aereus", "value": 0.1 } ] }
        """
        let scored = try JSONDecoder().decode(ScoredCoin.self, from: Data(json.utf8))
        #expect(scored.species.map(\.id) == ["craterellus_cornucopioides", "boletus_edulis", "boletus_aereus"])
        #expect(CoinTrend.worthSpecies(scored, min: 0.3).map(\.id) == ["craterellus_cornucopioides", "boletus_edulis"])
        // rien n'atteint le seuil : la ligne ne nomme aucune espèce
        #expect(CoinTrend.worthSpecies(scored, min: 0.7).isEmpty)
        // serveur d'avant `species` : l'espèce qui porte le score, si elle atteint le seuil
        let old = ScoredCoin(id: id, name: "Combe", score: 0.4, leading: "boletus_edulis", bestDay: nil, best: nil, days: [])
        #expect(old.species.isEmpty)
        #expect(CoinTrend.worthSpecies(old, min: 0.3) == [CoinSpeciesScore(id: "boletus_edulis", value: 0.4)])
        #expect(CoinTrend.worthSpecies(old, min: 0.5).isEmpty)
    }
}
