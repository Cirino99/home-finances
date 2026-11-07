import Core
import Foundation
import Testing
@testable import Persistence

struct MovementRepositoryTests {
    // MARK: Elenco

    @Test func mixesOperationsAndTransfersInOrder() async throws {
        let fixture = try await Fixture()
        let savings = try await fixture.addAccount()
        let older = try await fixture.addOperation(.expense, amount: 100, on: "2026-11-06")
        fixture.clock.advance(by: 1)
        let sameDayFirst = try await fixture.addOperation(.income, amount: 200, on: "2026-11-07")
        fixture.clock.advance(by: 1)
        let sameDayLater = try await fixture.addTransfer(amount: 300, on: "2026-11-07", from: fixture.account, to: savings)

        let ids = try await fixture.movements().map(\.id)
        #expect(ids == [.transfer(sameDayLater.id), .operation(sameDayFirst.id), .operation(older.id)])
    }

    @Test func pagesHaveNoGapsOrDuplicates() async throws {
        let fixture = try await Fixture()
        let savings = try await fixture.addAccount()
        var expected: Set<MovementID> = []
        for day in 1...5 {
            let operation = try await fixture.addOperation(.expense, amount: 100, on: String(format: "2026-10-%02d", day))
            let transfer = try await fixture.addTransfer(
                amount: 100, on: String(format: "2026-10-%02d", day), from: fixture.account, to: savings
            )
            expected.formUnion([.operation(operation.id), .transfer(transfer.id)])
        }

        var seen: [MovementID] = []
        for offset in stride(from: 0, to: 10, by: 3) {
            seen += try await fixture.movements(MovementQuery(limit: 3, offset: offset)).map(\.id)
        }
        #expect(seen.count == 10)
        #expect(Set(seen) == expected)
        #expect(try await fixture.movements(MovementQuery(limit: 10)).map(\.id) == seen)
    }

    @Test func filtersByKind() async throws {
        let fixture = try await Fixture()
        let savings = try await fixture.addAccount()
        let income = try await fixture.addOperation(.income, amount: 100, on: "2026-11-01")
        let expense = try await fixture.addOperation(.expense, amount: 100, on: "2026-11-02")
        let transfer = try await fixture.addTransfer(amount: 100, on: "2026-11-03", from: fixture.account, to: savings)

        #expect(try await fixture.movements(MovementQuery(kind: .income)).map(\.id) == [.operation(income.id)])
        #expect(try await fixture.movements(MovementQuery(kind: .expense)).map(\.id) == [.operation(expense.id)])
        #expect(try await fixture.movements(MovementQuery(kind: .transfer)).map(\.id) == [.transfer(transfer.id)])
        #expect(try await fixture.movements().count == 3)
    }

    @Test func categoryExcludesTransfers() async throws {
        let fixture = try await Fixture()
        let savings = try await fixture.addAccount()
        let expense = try await fixture.addOperation(.expense, amount: 100, on: "2026-11-02")
        try await fixture.addTransfer(amount: 100, on: "2026-11-03", from: fixture.account, to: savings)

        let ids = try await fixture.movements(MovementQuery(categoryID: fixture.expenseCategory.id)).map(\.id)
        #expect(ids == [.operation(expense.id)])
    }

    @Test func accountFilterIncludesBothDirections() async throws {
        let fixture = try await Fixture()
        let savings = try await fixture.addAccount("Risparmi")
        let cash = try await fixture.addAccount("Contanti")
        let onSavings = try await fixture.addOperation(.expense, amount: 100, on: "2026-11-01", account: savings)
        try await fixture.addOperation(.expense, amount: 100, on: "2026-11-02")
        let incoming = try await fixture.addTransfer(amount: 500, on: "2026-11-03", from: fixture.account, to: savings)
        let outgoing = try await fixture.addTransfer(amount: 200, on: "2026-11-04", from: savings, to: cash)
        try await fixture.addTransfer(amount: 50, on: "2026-11-05", from: fixture.account, to: cash)

        let items = try await fixture.movements(MovementQuery(accountID: savings.id))
        #expect(items.map(\.id) == [.transfer(outgoing.id), .transfer(incoming.id), .operation(onSavings.id)])
        #expect(items.map { $0.signedAmount(for: savings.id) } == [-200, 500, -100])
    }

    @Test func searchesNotesCategoriesAndAccountNames() async throws {
        let fixture = try await Fixture()
        let savings = try await fixture.addAccount("Libretto postale")
        let byNote = try await fixture.addOperation(.expense, amount: 100, on: "2026-11-01", note: "regalo postale")
        let byAccount = try await fixture.addTransfer(amount: 100, on: "2026-11-02", from: fixture.account, to: savings)
        let byTransferNote = try await fixture.addTransfer(
            amount: 100, on: "2026-11-03", from: savings, to: fixture.account, note: "Rientro 100%"
        )

        let postal = try await fixture.movements(MovementQuery(searchText: "postale")).map(\.id)
        #expect(Set(postal) == [.operation(byNote.id), .transfer(byAccount.id), .transfer(byTransferNote.id)])

        // `%` è un carattere normale, non un jolly.
        let percent = try await fixture.movements(MovementQuery(searchText: "100%")).map(\.id)
        #expect(percent == [.transfer(byTransferNote.id)])

        let category = try await fixture.movements(MovementQuery(searchText: fixture.expenseCategory.name)).map(\.id)
        #expect(category == [.operation(byNote.id)])
    }

    @Test func filtersByMonth() async throws {
        let fixture = try await Fixture()
        let savings = try await fixture.addAccount()
        try await fixture.addOperation(.expense, amount: 100, on: "2026-10-31")
        let inMonth = try await fixture.addTransfer(amount: 100, on: "2026-11-01", from: fixture.account, to: savings)
        try await fixture.addTransfer(amount: 100, on: "2026-12-01", from: fixture.account, to: savings)

        let month = try #require(YearMonth(year: 2026, month: 11))
        #expect(try await fixture.movements(MovementQuery(month: month)).map(\.id) == [.transfer(inMonth.id)])
    }

    @Test func updatesAfterWrites() async throws {
        let fixture = try await Fixture()
        let savings = try await fixture.addAccount()
        var iterator = fixture.database.movements.observeMovements(MovementQuery()).makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty == true)

        try await fixture.addTransfer(amount: 100, on: "2026-11-01", from: fixture.account, to: savings)
        #expect(try await iterator.next()?.count == 1)
    }

    // MARK: Totali e saldi

    /// Spostare soldi tra i propri conti non è guadagnare né spendere (§ 6.4).
    @Test func transfersDoNotChangeIncomeAndExpenseTotals() async throws {
        let fixture = try await Fixture()
        let savings = try await fixture.addAccount()
        try await fixture.addOperation(.income, amount: 1000, on: "2026-11-01")
        try await fixture.addOperation(.expense, amount: 300, on: "2026-11-02")
        let month = try #require(YearMonth(year: 2026, month: 11))
        let operations = fixture.database.operations

        let monthBefore = try await operations.observeTotals(for: month).firstValue()
        let monthsBefore = try await operations.observeMonthlyTotals(year: nil).firstValue()
        let yearsBefore = try await operations.observeYearlyTotals().firstValue()

        try await fixture.addTransfer(amount: 500, on: "2026-11-03", from: fixture.account, to: savings)
        try await fixture.addTransfer(amount: 500, on: "2025-06-03", from: savings, to: fixture.account)

        #expect(try await operations.observeTotals(for: month).firstValue() == monthBefore)
        #expect(try await operations.observeMonthlyTotals(year: nil).firstValue() == monthsBefore)
        #expect(try await operations.observeYearlyTotals().firstValue() == yearsBefore)
        #expect(monthBefore == PeriodTotals(income: 1000, expense: 300))
    }

    @Test func balancesCombineAllMovements() async throws {
        let fixture = try await Fixture()
        let savings = try await fixture.addAccount("Risparmi", initialBalance: 10000)
        try await fixture.addOperation(.income, amount: 5000, on: "2026-11-01")
        try await fixture.addOperation(.expense, amount: 1500, on: "2026-11-02")
        try await fixture.addOperation(.expense, amount: 700, on: "2026-11-03", account: savings)
        try await fixture.addTransfer(amount: 2000, on: "2026-11-04", from: fixture.account, to: savings)
        // Anche una data futura conta (§ 6.4).
        try await fixture.addTransfer(amount: 300, on: "2030-01-01", from: savings, to: fixture.account)

        let balances = try await fixture.balances()
        #expect(balances.map(\.account.id) == [fixture.account.id, savings.id])
        #expect(balances[0].balance == 5000 - 1500 - 2000 + 300)
        #expect(balances[1].balance == 10000 - 700 + 2000 - 300)
        #expect(AccountBalance.total(of: balances) == 10000 + 5000 - 1500 - 700)
    }

    @Test func balancesIncludeArchivedAccounts() async throws {
        let fixture = try await Fixture()
        let old = try await fixture.addAccount("Vecchio", initialBalance: 400)
        try await fixture.database.accounts.setArchived(old.id, isArchived: true)

        let balances = try await fixture.balances()
        let archived = try #require(balances.first { $0.account.id == old.id })
        #expect(archived.account.isArchived)
        #expect(archived.balance == 400)
        #expect(AccountBalance.total(of: balances) == 400)
    }
}
