import Core
import Foundation
import Persistence
import Testing
@testable import HistoryFeature

@MainActor
struct HistoryModelsTests {
    let database: AppDatabase
    let repositories: HistoryRepositories
    let account: Account
    let expense: OperationCategory
    let income: OperationCategory

    init() async throws {
        let database = try AppDatabase.inMemory()
        try await database.seedIfNeeded(currency: "EUR")
        self.database = database
        repositories = HistoryRepositories(
            operations: database.operations,
            transfers: database.transfers,
            movements: database.movements,
            categories: database.categories,
            accounts: database.accounts
        )
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

    @discardableResult
    func add(_ kind: OperationKind, amount: Int64, on date: String, note: String? = nil) async throws -> FinanceOperation {
        try await database.operations.create(OperationDraft(
            kind: kind,
            amount: amount,
            date: try #require(Day(string: date)),
            accountID: account.id,
            categoryID: kind == .expense ? expense.id : income.id,
            note: note
        ))
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Condizione non raggiunta in tempo")
    }

    /// Come `.task(id: model.query)` nella vista: una lettura alla volta.
    func load(_ model: OperationListModel, expecting count: Int) async throws {
        let task = Task { await model.observeItems() }
        defer { task.cancel() }
        try await waitUntil { model.hasLoaded && model.items.count == count }
    }

    // MARK: Elenco

    @Test func groupsByDayMostRecentFirst() async throws {
        try await add(.expense, amount: 1, on: "2026-10-26")
        try await add(.expense, amount: 2, on: "2026-10-30")
        try await add(.income, amount: 3, on: "2026-10-30")

        let model = OperationListModel(month: nil, repositories: repositories)
        try await load(model, expecting: 3)

        #expect(model.sections.map(\.day.string) == ["2026-10-30", "2026-10-26"])
        #expect(model.sections.map(\.items.count) == [2, 1])
    }

    @Test func noItemsMeansNoSections() async throws {
        let model = OperationListModel(month: nil, repositories: repositories)
        try await load(model, expecting: 0)
        #expect(model.sections.isEmpty)
        #expect(!model.hasMore)
    }

    @Test func limitsToTheMonth() async throws {
        try await add(.expense, amount: 1, on: "2026-09-30")
        try await add(.expense, amount: 2, on: "2026-10-01")

        let model = OperationListModel(month: YearMonth(year: 2026, month: 10), repositories: repositories)
        try await load(model, expecting: 1)
        #expect(model.items.first?.signedAmount(for: nil) == -2)

        let task = Task { await model.observeTotals() }
        defer { task.cancel() }
        try await waitUntil { model.totals == PeriodTotals(income: 0, expense: 2) }
    }

    @Test func loadsPagesOnRequest() async throws {
        for day in 1...5 {
            try await add(.expense, amount: Int64(day), on: String(format: "2026-10-%02d", day))
        }
        let model = OperationListModel(month: nil, repositories: repositories, pageSize: 2)
        try await load(model, expecting: 2)
        #expect(model.hasMore)

        model.loadMore()
        #expect(model.query.limit == 4)
        try await load(model, expecting: 4)
        #expect(model.hasMore)

        model.loadMore()
        try await load(model, expecting: 5)
        #expect(!model.hasMore, "Pagina incompleta: non ce ne sono altre")
    }

    @Test func changingSearchOrFiltersRestartsFromFirstPage() async throws {
        let model = OperationListModel(month: nil, repositories: repositories, pageSize: 2)
        for day in 1...3 {
            try await add(.expense, amount: Int64(day), on: String(format: "2026-10-%02d", day))
        }
        try await load(model, expecting: 2)
        model.loadMore()
        #expect(model.query.limit == 4)

        model.searchText = "x"
        #expect(model.query.limit == 2)

        model.searchText = ""
        model.loadMore()
        model.kind = .expense
        #expect(model.query.limit == 2)
    }

    @Test func filtersBySearchAndKind() async throws {
        let coffee = try await add(.expense, amount: 1, on: "2026-10-10", note: "Caffè")
        let salary = try await add(.income, amount: 2, on: "2026-10-11")

        let searching = OperationListModel(month: nil, repositories: repositories)
        searching.searchText = "caff"
        #expect(searching.isSearching)
        try await load(searching, expecting: 1)
        #expect(searching.items.first?.id == .operation(coffee.id))

        let filtering = OperationListModel(month: nil, repositories: repositories)
        filtering.kind = .income
        #expect(filtering.isFiltering)
        try await load(filtering, expecting: 1)
        #expect(filtering.items.first?.id == .operation(salary.id))

        filtering.clearFilters()
        #expect(!filtering.isFiltering)
    }

    @Test func changingKindDropsIncompatibleCategoryFilter() async throws {
        let model = OperationListModel(month: nil, repositories: repositories)
        let task = Task { await model.observeCategories() }
        defer { task.cancel() }
        try await waitUntil { !model.categories.isEmpty }

        model.categoryID = expense.id
        model.kind = .expense
        #expect(model.categoryID == expense.id)
        #expect(model.visibleCategories.allSatisfy { $0.kind == .expense })

        model.kind = .income
        #expect(model.categoryID == nil)
    }

    @Test func listUpdatesAfterDeleting() async throws {
        let operation = try await add(.expense, amount: 1, on: "2026-10-10")
        let model = OperationListModel(month: nil, repositories: repositories)
        let task = Task { await model.observeItems() }
        defer { task.cancel() }
        try await waitUntil { model.items.count == 1 }

        await model.delete(.operation(operation.id))
        #expect(!model.deleteFailed)
        try await waitUntil { model.items.isEmpty }
    }

    @Test func deleteFailureIsReported() async {
        let model = OperationListModel(month: nil, repositories: repositories)
        await model.delete(.operation(OperationID()))
        #expect(model.deleteFailed)
        model.clearDeleteFailure()
        #expect(!model.deleteFailed)
    }

    // MARK: Trasferimenti

    func addSavings() async throws -> Account {
        try await database.accounts.create(name: "Risparmi", currency: "EUR", initialBalance: 0)
    }

    @discardableResult
    func transfer(_ amount: Int64, on date: String, from: Account, to: Account) async throws -> AccountTransfer {
        try await database.transfers.create(TransferDraft(
            amount: amount,
            date: try #require(Day(string: date)),
            fromAccountID: from.id,
            toAccountID: to.id
        ))
    }

    @Test func listShowsTransfersWithOperations() async throws {
        let savings = try await addSavings()
        let operation = try await add(.expense, amount: 1, on: "2026-10-10")
        let moved = try await transfer(500, on: "2026-10-11", from: account, to: savings)

        let model = OperationListModel(month: nil, repositories: repositories)
        try await load(model, expecting: 2)
        #expect(model.items.map(\.id) == [.transfer(moved.id), .operation(operation.id)])
        #expect(model.sections.map(\.day.string) == ["2026-10-11", "2026-10-10"])
    }

    @Test func transferKindShowsOnlyTransfersAndNoCategories() async throws {
        let savings = try await addSavings()
        try await add(.expense, amount: 1, on: "2026-10-10")
        let moved = try await transfer(500, on: "2026-10-11", from: account, to: savings)

        let model = OperationListModel(month: nil, repositories: repositories)
        let task = Task { await model.observeCategories() }
        defer { task.cancel() }
        try await waitUntil { !model.categories.isEmpty }

        model.categoryID = expense.id
        model.kind = .transfer
        #expect(model.categoryID == nil, "I trasferimenti non hanno categoria")
        #expect(model.visibleCategories.isEmpty)
        try await load(model, expecting: 1)
        #expect(model.items.first?.id == .transfer(moved.id))
    }

    @Test func accountFilterShowsTransfersWithRelativeSign() async throws {
        let savings = try await addSavings()
        try await add(.expense, amount: 1, on: "2026-10-09")
        try await transfer(500, on: "2026-10-10", from: account, to: savings)
        try await transfer(200, on: "2026-10-11", from: savings, to: account)

        let model = OperationListModel(month: nil, repositories: repositories)
        model.accountID = savings.id
        #expect(model.isFiltering)
        try await load(model, expecting: 2)
        #expect(model.items.map { $0.signedAmount(for: model.accountID) } == [-200, 500])
    }

    @Test func showAccountReplacesOtherFiltersAndSearch() async throws {
        let savings = try await addSavings()
        let model = OperationListModel(month: nil, repositories: repositories)
        model.searchText = "caffè"
        model.kind = .expense
        model.categoryID = expense.id

        model.show(account: savings.id)
        #expect(model.accountID == savings.id)
        #expect(model.searchText.isEmpty)
        #expect(model.kind == nil)
        #expect(model.categoryID == nil)
        #expect(model.query == MovementQuery(searchText: "", accountID: savings.id, limit: MovementQuery.defaultPageSize))
    }

    @Test func filteredAccountIsShownAndAccountFilterAvailable() async throws {
        let model = OperationListModel(month: nil, repositories: repositories)
        let task = Task { await model.observeAccounts() }
        defer { task.cancel() }
        try await waitUntil { model.accounts.count == 1 }
        #expect(!model.showsAccountFilter, "Con un solo conto il filtro non serve")

        let savings = try await addSavings()
        try await waitUntil { model.accounts.count == 2 }
        #expect(model.showsAccountFilter)

        model.accountID = savings.id
        #expect(model.filteredAccount?.name == "Risparmi")
    }

    @Test func monthListIncludesTransfersButTotalsDoNot() async throws {
        let savings = try await addSavings()
        try await add(.expense, amount: 30, on: "2026-10-05")
        try await transfer(500, on: "2026-10-06", from: account, to: savings)

        let model = OperationListModel(month: YearMonth(year: 2026, month: 10), repositories: repositories)
        try await load(model, expecting: 2)

        let task = Task { await model.observeTotals() }
        defer { task.cancel() }
        try await waitUntil { model.totals == PeriodTotals(income: 0, expense: 30) }
    }

    @Test func deletesTransfer() async throws {
        let savings = try await addSavings()
        let moved = try await transfer(500, on: "2026-10-06", from: account, to: savings)
        let model = OperationListModel(month: nil, repositories: repositories)
        let task = Task { await model.observeItems() }
        defer { task.cancel() }
        try await waitUntil { model.items.count == 1 }

        await model.delete(.transfer(moved.id))
        #expect(!model.deleteFailed)
        try await waitUntil { model.items.isEmpty }
    }

    // MARK: Mesi

    func makeMonths(year: Int?) throws -> MonthsModel {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Rome"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 12)))
        return MonthsModel(year: year, repositories: repositories, now: now, calendar: calendar)
    }

    @Test func chartShowsLastTwelveMonthsIncludingEmptyOnes() async throws {
        try await add(.expense, amount: 100, on: "2026-03-01")
        try await add(.income, amount: 50, on: "2025-04-30")
        try await add(.expense, amount: 999, on: "2025-03-31")

        let model = try makeMonths(year: nil)
        let task = Task { await model.observeRows() }
        defer { task.cancel() }
        try await waitUntil { model.rows.count == 3 }

        let chart = model.chartMonths
        #expect(chart.count == 12)
        #expect(chart.first?.month == YearMonth(year: 2025, month: 4))
        #expect(chart.first?.totals == PeriodTotals(income: 50, expense: 0))
        #expect(chart.last?.month == YearMonth(year: 2026, month: 3))
        #expect(chart.last?.totals == PeriodTotals(income: 0, expense: 100))
        #expect(chart[1].totals == PeriodTotals(), "Mese senza operazioni")
        #expect(!chart.contains { $0.totals.expense == 999 }, "Fuori dagli ultimi 12 mesi")

        #expect(model.rows.count == 3, "L'elenco resta completo")
    }

    @Test func monthsOfAYearStayInThatYear() async throws {
        try await add(.expense, amount: 10, on: "2025-12-31")
        try await add(.expense, amount: 20, on: "2026-01-01")

        let model = try makeMonths(year: 2025)
        let task = Task { await model.observeRows() }
        defer { task.cancel() }
        try await waitUntil { model.hasLoaded }

        #expect(model.rows.map(\.month.string) == ["2025-12"])
        #expect(model.chartMonths.map(\.month.month) == Array(1...12))
        #expect(model.chartMonths.allSatisfy { $0.month.year == 2025 })
    }

    @Test func monthsUpdateAfterNewOperation() async throws {
        let model = try makeMonths(year: nil)
        let task = Task { await model.observeRows() }
        defer { task.cancel() }
        try await waitUntil { model.hasLoaded }
        #expect(model.rows.isEmpty)

        try await add(.expense, amount: 10, on: "2026-03-01")
        try await waitUntil { model.rows.count == 1 }
    }

    // MARK: Anni

    @Test func yearsAreListedRecentFirstAndChartedOldestFirst() async throws {
        try await add(.expense, amount: 10, on: "2024-06-01")
        try await add(.income, amount: 30, on: "2026-01-01")

        let model = YearsModel(repositories: repositories)
        let task = Task { await model.observeRows() }
        defer { task.cancel() }
        try await waitUntil { model.rows.count == 2 }

        #expect(model.rows.map(\.year) == [2026, 2024])
        #expect(model.chartYears.map(\.year) == [2024, 2026])
        #expect(model.chartYears.first?.totals.balance == -10)
    }
}
