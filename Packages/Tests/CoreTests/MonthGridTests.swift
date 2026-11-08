import Foundation
import Testing
@testable import Core

struct MonthGridTests {
    func day(_ string: String) throws -> Day {
        try #require(Day(string: string))
    }

    /// Confronto con `Calendar` di sistema, che è il riferimento per il giorno della settimana.
    @Test(arguments: ["2026-11-08", "2026-01-01", "2024-02-29", "2000-03-01", "1900-03-01", "2100-12-31"])
    func weekdayMatchesGregorianCalendar(string: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let date = try #require(try day(string).date(in: calendar))
        #expect(try day(string).weekday == calendar.component(.weekday, from: date))
    }

    @Test func addingDaysCrossesMonthsAndYears() throws {
        #expect(try day("2026-01-31").adding(days: 1) == day("2026-02-01"))
        #expect(try day("2024-02-28").adding(days: 1) == day("2024-02-29"))
        #expect(try day("2025-02-28").adding(days: 1) == day("2025-03-01"))
        #expect(try day("2026-12-31").adding(days: 1) == day("2027-01-01"))
        #expect(try day("2027-01-01").adding(days: -1) == day("2026-12-31"))
        #expect(try day("2026-11-08").adding(days: -7) == day("2026-11-01"))
        #expect(try day("2026-11-08").adding(days: 0) == day("2026-11-08"))
    }

    @Test func addingDaysStopsAtTheLimits() throws {
        #expect(try day("9999-12-31").adding(days: 1) == day("9999-12-31"))
        #expect(try day("0001-01-01").adding(days: -1) == day("0001-01-01"))
    }

    @Test func movingToShorterMonthKeepsLastDay() throws {
        #expect(try day("2026-01-31").moved(to: YearMonth(year: 2026, month: 2)!) == day("2026-02-28"))
        #expect(try day("2026-01-15").moved(to: YearMonth(year: 2026, month: 3)!) == day("2026-03-15"))
    }

    /// Novembre 2026 inizia di domenica: con il lunedì primo giorno ci sono 6 caselle vuote davanti.
    @Test func gridStartsOnTheChosenWeekday() throws {
        let november = try #require(YearMonth(year: 2026, month: 11))
        let firstOfNovember = try day("2026-11-01")

        let monday = MonthGrid(month: november, firstWeekday: 2)
        #expect(monday.weeks.first == [nil, nil, nil, nil, nil, nil, firstOfNovember])
        #expect(monday.weeks.allSatisfy { $0.count == 7 })
        #expect(monday.weeks.flatMap { $0 }.compactMap { $0 }.count == 30)
        #expect(monday.weeks.last?.last == .some(nil), "L'ultima settimana si completa con caselle vuote")

        let sunday = MonthGrid(month: november, firstWeekday: 1)
        #expect(sunday.weeks.first?.first == .some(firstOfNovember))
        #expect(sunday.weeks.count == 5)
    }

    @Test func februaryStartingOnFirstWeekdayFillsFourWeeks() throws {
        // Febbraio 2027 inizia di lunedì e ha 28 giorni: quattro settimane esatte.
        let grid = MonthGrid(month: try #require(YearMonth(year: 2027, month: 2)), firstWeekday: 2)
        #expect(grid.weeks.count == 4)
        #expect(grid.weeks.flatMap { $0 }.allSatisfy { $0 != nil })
    }

    @Test func weekdayOrderRotatesFromFirstWeekday() {
        #expect(MonthGrid.weekdayOrder(firstWeekday: 1) == [1, 2, 3, 4, 5, 6, 7])
        #expect(MonthGrid.weekdayOrder(firstWeekday: 2) == [2, 3, 4, 5, 6, 7, 1])
        #expect(MonthGrid.weekdayOrder(firstWeekday: 7) == [7, 1, 2, 3, 4, 5, 6])
    }
}
