import Core
import Foundation
import Persistence
import Testing
@testable import AccountsFeature

@MainActor
struct AccountsModelsTests {
    let database: AppDatabase
    let main: Account
    let expense: OperationCategory

    init() async throws {
        database = try AppDatabase.inMemory()
        try await database.seedIfNeeded(currency: "EUR")
        main = try #require(try await Self.first(database.accounts.observeAccounts(includingArchived: false)).first)
        let categories = try await Self.first(database.categories.observeCategories(includingArchived: false))
        expense = try #require(categories.first { $0.kind == .expense })
    }

    static func first<Value: Sendable>(_ stream: AsyncThrowingStream<Value, any Error>) async throws -> Value {
        for try await value in stream {
            return value
        }
        throw CancellationError()
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Condizione non raggiunta in tempo")
    }

    func addAccount(_ name: String, initialBalance: Int64 = 0) async throws -> Account {
        try await database.accounts.create(name: name, currency: "EUR", initialBalance: initialBalance)
    }

    @discardableResult
    func spend(_ amount: Int64, on date: String, from account: Account) async throws -> FinanceOperation {
        try await database.operations.create(OperationDraft(
            kind: .expense,
            amount: amount,
            date: try #require(Day(string: date)),
            accountID: account.id,
            categoryID: expense.id
        ))
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

    // MARK: Elenco dei conti

    @Test func singleAccountCannotTransfer() async throws {
        let model = AccountsModel(movements: database.movements)
        let task = Task { await model.observeBalances() }
        defer { task.cancel() }
        try await waitUntil { model.hasLoaded }

        #expect(model.activeBalances.map(\.account.id) == [main.id])
        #expect(model.total == 0)
        #expect(model.currency == "EUR")
        #expect(!model.canTransfer)
    }

    @Test func totalAndBalancesFollowMovements() async throws {
        let savings = try await addAccount("Risparmi", initialBalance: 100_000)
        let model = AccountsModel(movements: database.movements)
        let task = Task { await model.observeBalances() }
        defer { task.cancel() }
        try await waitUntil { model.activeBalances.count == 2 }
        #expect(model.canTransfer)
        #expect(model.total == 100_000)

        try await transfer(30_000, on: "2026-11-01", from: savings, to: main)
        try await spend(5_000, on: "2026-11-02", from: main)

        try await waitUntil { model.total == 95_000 }
        #expect(model.activeBalances.map(\.balance) == [25_000, 70_000])
    }

    @Test func archivedAccountsWithBalanceAreListedAndCounted() async throws {
        let empty = try await addAccount("Vuoto")
        let old = try await addAccount("Vecchio", initialBalance: 4_000)
        try await database.accounts.setArchived(empty.id, isArchived: true)
        try await database.accounts.setArchived(old.id, isArchived: true)

        let model = AccountsModel(movements: database.movements)
        let task = Task { await model.observeBalances() }
        defer { task.cancel() }
        try await waitUntil { model.hasLoaded }

        #expect(model.activeBalances.map(\.account.id) == [main.id])
        #expect(model.archivedBalances.map(\.account.id) == [old.id], "Un conto archiviato vuoto non si mostra")
        #expect(model.total == 4_000, "I soldi di un conto archiviato ci sono ancora")
        #expect(!model.canTransfer, "Contano solo i conti attivi")
    }

    // MARK: Dettaglio del conto

    @Test func detailShowsBalanceAndLastFiveMovementsOfTheAccount() async throws {
        let savings = try await addAccount("Risparmi", initialBalance: 50_000)
        for day in 1...4 {
            try await spend(100, on: String(format: "2026-11-%02d", day), from: savings)
        }
        try await spend(999, on: "2026-11-05", from: main)
        try await transfer(1_000, on: "2026-11-06", from: savings, to: main)
        try await transfer(2_000, on: "2026-11-07", from: main, to: savings)

        let model = AccountDetailModel(accountID: savings.id, movements: database.movements)
        let balanceTask = Task { await model.observeBalance() }
        let recentTask = Task { await model.observeRecent() }
        defer {
            balanceTask.cancel()
            recentTask.cancel()
        }
        try await waitUntil { model.hasLoadedBalance && model.hasLoadedRecent }

        // Valore atteso con un tipo esplicito: dentro `#expect`, un'espressione aritmetica confrontata
        // con un opzionale non viene letta come `Int64`, e il confronto fallisce anche a valori uguali.
        let expectedBalance: Int64 = 50_000 - 400 - 1_000 + 2_000
        #expect(model.balance?.balance == expectedBalance)
        #expect(model.recent.count == AccountDetailModel.recentLimit)
        #expect(model.recent.map { $0.signedAmount(for: savings.id) } == [2_000, -1_000, -100, -100, -100])
        #expect(model.showsTransferButton)
        #expect(model.canTransfer)
    }

    @Test func archivedAccountHasNoTransferButton() async throws {
        let old = try await addAccount("Vecchio", initialBalance: 1_000)
        try await database.accounts.setArchived(old.id, isArchived: true)

        let model = AccountDetailModel(accountID: old.id, movements: database.movements)
        let task = Task { await model.observeBalance() }
        defer { task.cancel() }
        try await waitUntil { model.hasLoadedBalance }

        #expect(model.balance?.balance == 1_000)
        #expect(!model.showsTransferButton)
    }

    @Test func missingAccountIsReported() async throws {
        let model = AccountDetailModel(accountID: AccountID(), movements: database.movements)
        let task = Task { await model.observeBalance() }
        defer { task.cancel() }
        try await waitUntil { model.hasLoadedBalance }

        #expect(model.isMissing)
        #expect(!model.showsTransferButton)
    }

    // MARK: Router

    @Test func lockAndImportCloseAccountManagementAndPath() {
        let router = AppRouter()
        router.accountsPath = [.account(main.id)]
        router.isAccountManagementPresented = true

        router.dismissPresentations()
        #expect(!router.isAccountManagementPresented)
        #expect(router.accountsPath == [.account(main.id)], "Dopo lo sblocco si ritrova la stessa posizione")

        router.resetNavigation()
        #expect(router.accountsPath.isEmpty)
    }
}
