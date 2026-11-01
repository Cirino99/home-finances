import Foundation
import Testing
@testable import Core

struct CalendarTypesTests {
    @Test(arguments: [
        (2026, 1, 31), (2026, 2, 28), (2024, 2, 29), (2000, 2, 29), (1900, 2, 28), (2026, 4, 30), (2026, 12, 31),
    ])
    func lastDayOfMonth(year: Int, month: Int, expected: Int) throws {
        let yearMonth = try #require(YearMonth(year: year, month: month))
        #expect(yearMonth.dayCount == expected)
        #expect(yearMonth.lastDay.day == expected)
        #expect(yearMonth.firstDay.day == 1)
    }

    @Test func rejectsImpossibleDates() {
        #expect(Day(year: 2026, month: 2, day: 29) == nil)
        #expect(Day(year: 2026, month: 13, day: 1) == nil)
        #expect(Day(year: 2026, month: 4, day: 31) == nil)
        #expect(Day(year: 2026, month: 1, day: 0) == nil)
        #expect(YearMonth(year: 2026, month: 0) == nil)
    }

    @Test func parsesAndFormatsStrings() {
        #expect(Day(string: "2026-10-30")?.string == "2026-10-30")
        #expect(Day(string: "2024-02-29") != nil)
        #expect(Day(string: "2026-02-30") == nil)
        #expect(Day(string: "2026-1-05") == nil)
        #expect(Day(string: "30/10/2026") == nil)
        #expect(YearMonth(string: "2026-03")?.string == "2026-03")
        #expect(YearMonth(string: "2026-13") == nil)
    }

    @Test func movesAcrossYearBoundaries() {
        #expect(YearMonth(year: 2026, month: 12)?.next == YearMonth(year: 2027, month: 1))
        #expect(YearMonth(year: 2026, month: 1)?.previous == YearMonth(year: 2025, month: 12))
    }

    @Test func ordersChronologically() throws {
        let earlier = try #require(Day(string: "2025-12-31"))
        let later = try #require(Day(string: "2026-01-01"))
        #expect(earlier < later)
        #expect(earlier.yearMonth < later.yearMonth)
    }

    /// Il dispositivo può usare un altro calendario: le date dell'app restano gregoriane.
    @Test(arguments: [
        Calendar.Identifier.buddhist, .japanese, .hebrew, .islamicCivil, .persian, .chinese,
    ])
    func alwaysUsesGregorianDates(identifier: Calendar.Identifier) throws {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Rome"))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let date = try #require(gregorian.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 12)))

        let day = Day(containing: date, calendar: calendar)

        #expect(day.string == "2026-03-15")
        #expect(day.yearMonth == YearMonth(year: 2026, month: 3))
        #expect(YearMonth(containing: date, calendar: calendar).string == "2026-03")
        #expect(day.date(in: calendar) == gregorian.startOfDay(for: date))
    }

    /// Nel calendario ebraico Adar I è il mese 13, che non esiste nel gregoriano: non deve far crashare.
    @Test func hebrewLeapMonthDoesNotCrash() throws {
        var hebrew = Calendar(identifier: .hebrew)
        hebrew.timeZone = try #require(TimeZone(identifier: "Europe/Rome"))
        // Febbraio 2027 cade in un anno ebraico bisestile.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = hebrew.timeZone
        let date = try #require(gregorian.date(from: DateComponents(year: 2027, month: 2, day: 20, hour: 12)))

        #expect(Day(containing: date, calendar: hebrew).yearMonth.string == "2027-02")
    }

    @Test func extremeYearsStayInRange() {
        let farPast = Date(timeIntervalSinceReferenceDate: -100_000_000_000)
        #expect(Day(containing: farPast).yearMonth.year >= 1)
        let farFuture = Date(timeIntervalSinceReferenceDate: 1_000_000_000_000)
        #expect(Day(containing: farFuture).yearMonth.year <= 9999)
    }

    /// Lo stesso istante cade in mesi diversi a seconda del fuso: conta quello del dispositivo (§ 6.4).
    @Test func currentMonthDependsOnDeviceTimeZone() throws {
        let instant = Date(timeIntervalSince1970: 1_798_761_600) // 2027-01-01 00:00 UTC
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))

        #expect(YearMonth(containing: instant, calendar: utc) == YearMonth(year: 2027, month: 1))
        #expect(YearMonth(containing: instant, calendar: newYork) == YearMonth(year: 2026, month: 12))
    }
}
