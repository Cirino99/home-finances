import Foundation
import Testing
@testable import Core

struct DayFormatTests {
    let italian = Locale(identifier: "it_IT")
    let calendar: Calendar

    init() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Rome"))
        self.calendar = calendar
    }

    func relative(_ day: String, today: String) throws -> String {
        DayFormat.relative(
            try #require(Day(string: day)),
            today: try #require(Day(string: today)),
            calendar: calendar,
            locale: italian
        )
    }

    @Test func todayAndYesterday() throws {
        #expect(try relative("2026-10-30", today: "2026-10-30") == "Oggi")
        #expect(try relative("2026-10-29", today: "2026-10-30") == "Ieri")
    }

    @Test func yesterdayAcrossMonthAndYear() throws {
        #expect(try relative("2026-09-30", today: "2026-10-01") == "Ieri")
        #expect(try relative("2025-12-31", today: "2026-01-01") == "Ieri")
    }

    /// Il cambio dell'ora legale fa durare 25 ore il 25 ottobre 2026 a Roma.
    @Test func yesterdayAcrossDaylightSavingChange() throws {
        #expect(try relative("2026-10-25", today: "2026-10-26") == "Ieri")
    }

    @Test func olderDatesOmitYearIfSame() throws {
        #expect(try relative("2026-10-12", today: "2026-10-30") == "12 ott")
        #expect(try relative("2025-10-12", today: "2026-10-30").contains("2025"))
    }

    @Test func futureDateIsNotYesterday() throws {
        #expect(try relative("2026-10-31", today: "2026-10-30") == "31 ott")
    }

    @Test func monthTitleIsCapitalized() throws {
        let month = try #require(YearMonth(year: 2026, month: 10))
        #expect(DayFormat.monthTitle(month, calendar: calendar, locale: italian) == "Ottobre 2026")
    }

    @Test func longDateIncludesMonthName() throws {
        let day = try #require(Day(string: "2026-10-30"))
        #expect(DayFormat.long(day, calendar: calendar, locale: italian) == "30 ottobre 2026")
    }
}
