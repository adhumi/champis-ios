import Foundation

/// Lecture en mots des onze jours d'un coin (refonte UX, lot 1, décision du 1er nov. 2026) :
/// « mieux dimanche » si un jour à venir passe au moins « bon », sinon « stable toute la semaine »
/// ou « en baisse ». Aucun chiffre ; le seuil « bon » vient de la palette, jamais d'ici.
nonisolated enum CoinTrend {
    enum Kind: Equatable, Sendable {
        /// Un jour à venir fait mieux qu'aujourd'hui et atteint au moins « bon » (jour ISO).
        case better(day: String)
        case stable
        case falling
        /// Pas de météo aujourd'hui, ou aucun jour à venir.
        case unknown
    }

    /// En dessous de cet écart, deux jours se valent.
    static let tolerance = 0.05

    static func kind(days: [CoinDay], today: String, goodMin: Double) -> Kind {
        guard let current = days.first(where: { $0.date == today })?.value else { return .unknown }
        let future = days.filter { $0.date > today }.compactMap { day in day.value.map { (day.date, $0) } }
        guard let best = future.max(by: { $0.1 < $1.1 }) else { return .unknown }
        if best.1 >= goodMin, best.1 > current + tolerance {
            return .better(day: best.0)
        }
        if best.1 < current - tolerance {
            return .falling
        }
        return .stable
    }

    static func phrase(_ kind: Kind) -> String? {
        switch kind {
        case .better(let day): "mieux \(weekdayName(iso: day))"
        case .stable: "stable toute la semaine"
        case .falling: "en baisse"
        case .unknown: nil
        }
    }

    /// Coins classés du meilleur au moins bon ; sans météo en dernier ; à égalité, par nom.
    static func order(_ coins: [Coin], scores: [UUID: ScoredCoin]) -> [Coin] {
        coins.sorted { a, b in
            let sa = scores[a.id]?.score
            let sb = scores[b.id]?.score
            switch (sa, sb) {
            case let (x?, y?) where x != y: return x > y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    // MARK: - Dates en français, sans dépendre de la locale de l'appareil

    private static let weekdays = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]
    private static let shortWeekdays = ["dim.", "lun.", "mar.", "mer.", "jeu.", "ven.", "sam."]
    private static let initials = ["d", "l", "m", "m", "j", "v", "s"]

    /// `2026-11-01` → `dimanche`.
    static func weekdayName(iso: String) -> String {
        weekdays[weekdayIndex(iso: iso)]
    }

    /// `2026-11-01` → `dim. 1`.
    static func shortDay(iso: String) -> String {
        let day = Int(iso.suffix(2)) ?? 0
        return "\(shortWeekdays[weekdayIndex(iso: iso)]) \(day)"
    }

    /// `2026-11-01` → `d` (l'initiale sous chaque pastille).
    static func initial(iso: String) -> String {
        initials[weekdayIndex(iso: iso)]
    }

    /// 0 = dimanche … 6 = samedi ; une date illisible renvoie 0.
    static func weekdayIndex(iso: String) -> Int {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            return 0
        }
        return calendar.component(.weekday, from: date) - 1
    }
}
