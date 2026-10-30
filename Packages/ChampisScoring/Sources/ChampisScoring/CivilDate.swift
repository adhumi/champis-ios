import Foundation

/// Date civile (année, mois, jour), sans fuseau ni heure : c'est ce que le modèle manipule
/// (jour de l'année, « MM-DD », différences en jours). Jamais de timestamp (skill `scoring-parity`).
public struct CivilDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// `YYYY-MM-DD`.
    public init(iso: String) throws {
        let parts = iso.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1, d <= CivilDate.daysIn(month: m, year: y)
        else { throw ScoringError.invalidDate(iso) }
        self.init(year: y, month: m, day: d)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    public static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: 31
        case 4, 6, 9, 11: 30
        default: isLeap(year) ? 29 : 28
        }
    }

    private static let cumulative = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]

    /// 1 pour le 1er janvier, comme `timetuple().tm_yday`.
    public var dayOfYear: Int {
        CivilDate.cumulative[month - 1] + day + (month > 2 && CivilDate.isLeap(year) ? 1 : 0)
    }

    /// Nombre de jours depuis le 1er janvier de l'an 1 (proleptique grégorien), comme `date.toordinal()`.
    public var ordinal: Int {
        let y = year - 1
        return y * 365 + y / 4 - y / 100 + y / 400 + dayOfYear
    }

    public init(ordinal: Int) {
        // inverse de `ordinal`, algorithme de `datetime.date.fromordinal`
        var n = ordinal - 1
        let n400 = n / 146_097
        n %= 146_097
        let n100 = n / 36524
        n %= 36524
        let n4 = n / 1461
        n %= 1461
        let n1 = n / 365
        n %= 365
        var y = n400 * 400 + n100 * 100 + n4 * 4 + n1 + 1
        if n1 == 4 || n100 == 4 {
            y -= 1
            self.init(year: y, month: 12, day: 31)
            return
        }
        var m = 1
        var rest = n + 1
        while rest > CivilDate.daysIn(month: m, year: y) {
            rest -= CivilDate.daysIn(month: m, year: y)
            m += 1
        }
        self.init(year: y, month: m, day: rest)
    }

    public func adding(days: Int) -> CivilDate {
        CivilDate(ordinal: ordinal + days)
    }

    /// `self − other` en jours.
    public func days(since other: CivilDate) -> Int {
        ordinal - other.ordinal
    }

    public static func < (lhs: CivilDate, rhs: CivilDate) -> Bool {
        lhs.ordinal < rhs.ordinal
    }

    /// `MM-DD` → (mois, jour), comme `_parse_md`.
    static func monthDay(_ s: String) throws -> (Int, Int) {
        let parts = s.split(separator: "-")
        guard parts.count == 2, let m = Int(parts[0]), let d = Int(parts[1]) else {
            throw ScoringError.invalidDate(s)
        }
        return (m, d)
    }

    /// Jour de l'année d'un `MM-DD` pour `year` ; un 29 février compte comme le 28 (comme `_day_of_year`).
    static func dayOfYear(month: Int, day: Int, year: Int) -> Int {
        var d = day
        if month == 2, d == 29 { d = 28 }
        return CivilDate(year: year, month: month, day: d).dayOfYear
    }
}
