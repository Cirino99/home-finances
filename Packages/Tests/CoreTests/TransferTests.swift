import Foundation
import Testing
@testable import Core

struct TransferDraftTests {
    let from = AccountID()
    let to = AccountID()

    func makeDraft(amount: Int64 = 100, sameAccount: Bool = false, note: String? = nil) throws -> TransferDraft {
        TransferDraft(
            amount: amount,
            date: try #require(Day(string: "2026-11-07")),
            fromAccountID: from,
            toAccountID: sameAccount ? from : to,
            note: note
        )
    }

    @Test func validDraftPasses() throws {
        try makeDraft().validate()
    }

    @Test(arguments: [0, -1] as [Int64])
    func amountMustBePositive(amount: Int64) throws {
        let draft = try makeDraft(amount: amount)
        #expect(throws: TransferDraftError.amountNotPositive) {
            try draft.validate()
        }
    }

    @Test func accountsMustDiffer() throws {
        let draft = try makeDraft(sameAccount: true)
        #expect(throws: TransferDraftError.sameAccount) {
            try draft.validate()
        }
    }

    @Test func noteHasMaximumLength() throws {
        try makeDraft(note: String(repeating: "a", count: 200)).validate()

        let tooLong = try makeDraft(note: String(repeating: "a", count: 201))
        #expect(throws: TransferDraftError.noteTooLong) {
            try tooLong.validate()
        }
    }

    @Test func noteIsNormalized() throws {
        #expect(try makeDraft(note: "  affitto \n").normalizedNote == "affitto")
        #expect(try makeDraft(note: "   ").normalizedNote == nil)
    }

    @Test func swapExchangesAccounts() throws {
        var draft = try makeDraft()
        draft.swapAccounts()
        #expect(draft.fromAccountID == to)
        #expect(draft.toAccountID == from)
    }
}

struct MovementTests {
    static let date = Date(timeIntervalSince1970: 0)
    let from = AccountID()
    let to = AccountID()

    func makeTransfer(amount: Int64 = 5000) throws -> AccountTransfer {
        AccountTransfer(
            id: TransferID(),
            amount: amount,
            currency: "EUR",
            date: try #require(Day(string: "2026-11-07")),
            fromAccountID: from,
            toAccountID: to,
            note: nil,
            createdAt: Self.date,
            updatedAt: Self.date
        )
    }

    func makeOperation(kind: OperationKind, amount: Int64) throws -> OperationListItem {
        OperationListItem(
            operation: FinanceOperation(
                id: OperationID(),
                kind: kind,
                amount: amount,
                currency: "EUR",
                date: try #require(Day(string: "2026-11-07")),
                accountID: from,
                categoryID: CategoryID(),
                note: nil,
                createdAt: Self.date,
                updatedAt: Self.date
            ),
            category: OperationCategory(
                id: CategoryID(),
                name: "Spesa",
                kind: kind,
                symbol: "cart",
                color: .green,
                isArchived: false,
                sortOrder: 0,
                createdAt: Self.date,
                updatedAt: Self.date
            ),
            accountName: "Conto principale"
        )
    }

    @Test func transferSignDependsOnAccount() throws {
        let transfer = try makeTransfer()
        #expect(transfer.signedAmount(for: from) == -5000)
        #expect(transfer.signedAmount(for: to) == 5000)
        #expect(transfer.signedAmount(for: AccountID()) == nil)
        #expect(transfer.signedAmount(for: nil) == nil)
    }

    @Test func operationSignDependsOnKind() throws {
        let income = MovementListItem.operation(try makeOperation(kind: .income, amount: 300))
        let expense = MovementListItem.operation(try makeOperation(kind: .expense, amount: 300))
        #expect(income.signedAmount(for: nil) == 300)
        #expect(expense.signedAmount(for: nil) == -300)
        #expect(expense.signedAmount(for: AccountID()) == -300)
    }

    @Test func movementIdentifiesItsKind() throws {
        let transfer = try makeTransfer()
        let item = MovementListItem.transfer(
            TransferListItem(transfer: transfer, fromAccountName: "Conto principale", toAccountName: "Risparmi")
        )
        #expect(item.id == .transfer(transfer.id))
        #expect(item.date == transfer.date)
        #expect(item.signedAmount(for: to) == 5000)
    }

    @Test func transferTitleShowsBothAccounts() throws {
        let item = TransferListItem(transfer: try makeTransfer(), fromAccountName: "Conto principale", toAccountName: "Risparmi")
        #expect(item.title == "Conto principale → Risparmi")
    }

    @Test func movementKindMapsOperationKinds() {
        #expect(MovementKind(.income) == .income)
        #expect(MovementKind(.expense) == .expense)
        #expect(MovementKind.income.operationKind == .income)
        #expect(MovementKind.transfer.operationKind == nil)
    }

    @Test func queryIncludesTablesByFilter() {
        #expect(MovementQuery().includesOperations)
        #expect(MovementQuery().includesTransfers)

        #expect(MovementQuery(kind: .income).includesOperations)
        #expect(!MovementQuery(kind: .income).includesTransfers)

        #expect(!MovementQuery(kind: .transfer).includesOperations)
        #expect(MovementQuery(kind: .transfer).includesTransfers)

        // Una categoria esclude i trasferimenti, che non ne hanno.
        #expect(MovementQuery(categoryID: CategoryID()).includesOperations)
        #expect(!MovementQuery(categoryID: CategoryID()).includesTransfers)
        #expect(!MovementQuery(kind: .transfer, categoryID: CategoryID()).includesTransfers)

        // Il filtro per conto non esclude nessuna delle due.
        #expect(MovementQuery(accountID: AccountID()).includesOperations)
        #expect(MovementQuery(accountID: AccountID()).includesTransfers)
    }
}

struct AccountBalanceTests {
    func makeAccount(initialBalance: Int64 = 0, isArchived: Bool = false) -> Account {
        let date = Date(timeIntervalSince1970: 0)
        return Account(
            id: AccountID(),
            name: "Conto",
            currency: "EUR",
            initialBalance: initialBalance,
            isArchived: isArchived,
            sortOrder: 0,
            createdAt: date,
            updatedAt: date
        )
    }

    @Test func accountWithoutMovementsHasInitialBalance() {
        #expect(AccountBalance(account: makeAccount(initialBalance: -2500)).balance == -2500)
        #expect(AccountBalance(account: makeAccount()).balance == 0)
    }

    @Test func balanceCombinesAllMovements() {
        let balance = AccountBalance(
            account: makeAccount(initialBalance: 10000),
            income: 5000,
            expense: 3000,
            received: 2000,
            sent: 1500
        )
        // 100 + 50 − 30 + 20 − 15 = 125
        #expect(balance.balance == 12500)
    }

    @Test func totalIncludesArchivedAccounts() {
        let balances = [
            AccountBalance(account: makeAccount(initialBalance: 1000), received: 500),
            AccountBalance(account: makeAccount(initialBalance: 2000), sent: 500),
            AccountBalance(account: makeAccount(initialBalance: 300, isArchived: true)),
        ]
        #expect(AccountBalance.total(of: balances) == 3300)
        #expect(AccountBalance.total(of: []) == 0)
    }

    /// Un trasferimento sposta soldi senza cambiare il totale.
    @Test func transferDoesNotChangeTotal() {
        let before = [
            AccountBalance(account: makeAccount(initialBalance: 1000)),
            AccountBalance(account: makeAccount(initialBalance: 0)),
        ]
        let after = [
            AccountBalance(account: before[0].account, sent: 400),
            AccountBalance(account: before[1].account, received: 400),
        ]
        #expect(AccountBalance.total(of: before) == AccountBalance.total(of: after))
        #expect(after[0].balance == 600)
        #expect(after[1].balance == 400)
    }
}

@MainActor
struct AppRouterAccountFilterTests {
    @Test func showHistoryOpensOperationsFilteredOnAccount() {
        let router = AppRouter()
        let account = AccountID()
        router.selectedTab = .home
        router.historySegment = .months
        router.historyPath = [.year(2026)]

        router.showHistory(account: account)

        #expect(router.selectedTab == .history)
        #expect(router.historySegment == .operations)
        #expect(router.historyPath.isEmpty)
        #expect(router.pendingHistoryAccountFilter == account)
    }

    @Test func resetNavigationClearsPendingFilter() {
        let router = AppRouter()
        router.showHistory(account: AccountID())
        router.resetNavigation()
        #expect(router.pendingHistoryAccountFilter == nil)
    }
}
