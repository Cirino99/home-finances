import Foundation

extension Calendar {
    /// Stesso fuso orario, ma gregoriano: date e mesi dell'app sono sempre `YYYY-MM-DD` gregoriani,
    /// anche su un dispositivo con calendario buddista, giapponese o ebraico (che ha 13 mesi).
    var gregorianEquivalent: Calendar {
        guard identifier != .gregorian else { return self }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

/// Mese di calendario, senza fuso orario.
public struct YearMonth: Hashable, Comparable, Sendable, Codable {
    public let year: Int
    public let month: Int

    public init?(year: Int, month: Int) {
        guard (1...9999).contains(year), (1...12).contains(month) else { return nil }
        self.year = year
        self.month = month
    }

    /// Da `YYYY-MM`.
    public init?(string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]) else { return nil }
        self.init(year: year, month: month)
    }

    /// Mese corrente secondo calendario e fuso orario del dispositivo (§ 6.4).
    public init(containing date: Date, calendar: Calendar = .current) {
        let day = Day(containing: date, calendar: calendar)
        self = day.yearMonth
    }

    public var string: String {
        String(format: "%04d-%02d", year, month)
    }

    public var dayCount: Int {
        switch month {
        case 2: Self.isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    public var firstDay: Day {
        Day(uncheckedYear: year, month: month, day: 1)
    }

    public var lastDay: Day {
        Day(uncheckedYear: year, month: month, day: dayCount)
    }

    public var next: YearMonth? {
        month == 12 ? YearMonth(year: year + 1, month: 1) : YearMonth(year: year, month: month + 1)
    }

    public var previous: YearMonth? {
        month == 1 ? YearMonth(year: year - 1, month: 12) : YearMonth(year: year, month: month - 1)
    }

    public static func < (lhs: YearMonth, rhs: YearMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    private static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }
}

/// Data di un'operazione: un giorno di calendario, così non cambia mese viaggiando (§ 6.1).
public struct Day: Hashable, Comparable, Sendable, Codable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard let yearMonth = YearMonth(year: year, month: month),
              (1...yearMonth.dayCount).contains(day) else { return nil }
        self.init(uncheckedYear: year, month: month, day: day)
    }

    /// Da `YYYY-MM-DD`.
    public init?(string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    public init(containing date: Date, calendar: Calendar = .current) {
        let components = calendar.gregorianEquivalent.dateComponents([.year, .month, .day], from: date)
        self.init(
            // Limitato all'intervallo di `YearMonth`, anche per date estreme.
            uncheckedYear: min(max(components.year ?? 1, 1), 9999),
            month: components.month ?? 1,
            day: components.day ?? 1
        )
    }

    fileprivate init(uncheckedYear year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public var string: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var yearMonth: YearMonth {
        // Valido per costruzione.
        YearMonth(year: year, month: month)!
    }

    /// Mezzanotte di questo giorno nel calendario indicato, per mostrarlo o passarlo a un `DatePicker`.
    public func date(in calendar: Calendar = .current) -> Date? {
        calendar.gregorianEquivalent.date(from: DateComponents(year: year, month: month, day: day))
    }

    public static func < (lhs: Day, rhs: Day) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}
