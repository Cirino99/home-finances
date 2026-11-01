import Core
import Foundation
import Persistence
import Synchronization
import Testing
@testable import HomeFeature

@MainActor
struct HomeModelTests {
    let database: AppDatabase
    let calendar: Calendar
    let clock = TestClock()
    let account: Account
    let expense: OperationCategory
    let income: OperationCategory

    init() async throws {
        database = try AppDatabase.inMemory()
        try await database.seedIfNeeded(currency: "EUR")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Rome"))
        self.calendar = calendar
        clock.date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12)))

        account = try #require(try await Self.first(database.accounts.observeAccounts(includingArchived: false)).first)
        let categories = try await Self.first(database.categories.observeCategories(includingArchived: false))
        expense = try #require(categories.first { $0.kind == .expense })
        income = try #require(categories.first { $0.kind == .income })
    }

    static func first<Value: Sendable>(_ stream: AsyncThrowingStream<Value, any Error>) async throws -> Value {
        for try await value in stream {
            return value
        }
        throw CancellationError()
    }

    func makeModel() -> HomeModel {
        HomeModel(
            operations: database.operations,
            accounts: database.accounts,
            now: { [clock] in clock.date },
            calendar: calendar
        )
    }

    func add(_ kind: OperationKind, amount: Int64, on date: String) async throws {
        try await database.operations.create(OperationDraft(
            kind: kind,
            amount: amount,
            date: try #require(Day(string: date)),
            accountID: account.id,
            categoryID: kind == .expense ? expense.id : income.id
        ))
    }

    /// Le letture sono asincrone: si attende che il modello arrivi al valore previsto.
    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Condizione non raggiunta in tempo")
    }

    // MARK: Selettore del mese

    @Test func startsOnCurrentMonth() {
        let model = makeModel()
        #expect(model.month == YearMonth(year: 2026, month: 10))
        #expect(model.isCurrentMonth)
        #expect(!model.canGoToNextMonth)
    }

    @Test func cannotGoPastCurrentMonth() {
        let model = makeModel()
        model.goToNextMonth()
        #expect(model.month == YearMonth(year: 2026, month: 10))
    }

    @Test func navigatesAcrossYearsAndBack() {
        let model = makeModel()
        for _ in 0..<10 {
            model.goToPreviousMonth()
        }
        #expect(model.month == YearMonth(year: 2025, month: 12))
        #expect(model.canGoToNextMonth)
        #expect(!model.isCurrentMonth)

        model.goToNextMonth()
        #expect(model.month == YearMonth(year: 2026, month: 1))

        model.goToCurrentMonth()
        #expect(model.isCurrentMonth)
    }

    @Test func newMonthFollowsWhoWasOnCurrentMonth() throws {
        let model = makeModel()
        clock.date = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9)))
        model.refreshToday()
        #expect(model.today == Day(year: 2026, month: 11, day: 1))
        #expect(model.month == YearMonth(year: 2026, month: 11))
    }

    @Test func newMonthKeepsWhoWasOnAPastMonth() throws {
        let model = makeModel()
        model.goToPreviousMonth()
        clock.date = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9)))
        model.refreshToday()
        #expect(model.month == YearMonth(year: 2026, month: 9))
        #expect(model.canGoToNextMonth)
    }

    // MARK: Letture

    @Test func totalsFollowSelectedMonthAndUpdates() async throws {
        try await add(.income, amount: 1000, on: "2026-10-01")
        try await add(.expense, amount: 300, on: "2026-10-30")
        try await add(.expense, amount: 50, on: "2026-09-15")

        let model = makeModel()
        var task = Task { await model.observeTotals() }
        try await waitUntil { model.totals == PeriodTotals(income: 1000, expense: 300) }
        #expect(model.totals.balance == 700)

        // Nuova operazione mentre la Home è visibile.
        try await add(.expense, amount: 200, on: "2026-10-30")
        try await waitUntil { model.totals == PeriodTotals(income: 1000, expense: 500) }

        // Come `.task(id:)`: al cambio di mese la lettura si riavvia.
        task.cancel()
        model.goToPreviousMonth()
        task = Task { await model.observeTotals() }
        try await waitUntil { model.totals == PeriodTotals(income: 0, expense: 50) }
        task.cancel()
    }

    @Test func recentAreAbsoluteAndLimitedToThree() async throws {
        try await add(.expense, amount: 1, on: "2026-07-01")
        try await add(.expense, amount: 2, on: "2026-08-01")
        try await add(.expense, amount: 3, on: "2026-09-01")
        try await add(.expense, amount: 4, on: "2026-10-01")

        let model = makeModel()
        let task = Task { await model.observeRecent() }
        defer { task.cancel() }
        try await waitUntil { model.hasLoadedRecent }
        #expect(model.recent.map(\.operation.amount) == [4, 3, 2])

        // Cambiare mese non cambia le ultime operazioni.
        model.goToPreviousMonth()
        model.goToPreviousMonth()
        #expect(model.recent.map(\.operation.amount) == [4, 3, 2])
    }

    @Test func emptyDatabaseLoadsNoRecent() async throws {
        let model = makeModel()
        #expect(!model.hasLoadedRecent)
        let task = Task { await model.observeRecent() }
        defer { task.cancel() }
        try await waitUntil { model.hasLoadedRecent }
        #expect(model.recent.isEmpty)
    }

    @Test func readsCurrency() async throws {
        let model = makeModel()
        let task = Task { await model.observeCurrency() }
        defer { task.cancel() }
        try await waitUntil { model.currency != nil }
        #expect(model.currency == "EUR")
    }
}

/// Orologio controllato dai test.
final class TestClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 0))

    var date: Date {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
}
