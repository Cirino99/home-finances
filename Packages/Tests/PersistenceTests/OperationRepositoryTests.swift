import Core
import Foundation
import Testing
@testable import Persistence

struct OperationRepositoryTests {
    // MARK: CRUD

    @Test func createsOperationWithAccountCurrency() async throws {
        let fixture = try await Fixture()
        let created = try await fixture.addOperation(.expense, amount: 1234, on: "2026-10-30", note: "  caffè ")

        #expect(created.currency == "EUR")
        #expect(created.note == "caffè")
        #expect(created.createdAt == fixture.clock.now)
        #expect(try await fixture.database.operations.operation(created.id) == created)
    }

    @Test func updatesOperationKeepingCreationDate() async throws {
        let fixture = try await Fixture()
        let created = try await fixture.addOperation(.expense, amount: 100, on: "2026-10-30")
        fixture.clock.advance(by: 60)

        var draft = OperationDraft(
            kind: .income,
            amount: 200,
            date: try #require(Day(string: "2026-11-01")),
            accountID: fixture.account.id,
            categoryID: fixture.incomeCategory.id,
            note: "rimborso"
        )
        let updated = try await fixture.database.operations.update(created.id, with: draft)

        #expect(updated.kind == .income)
        #expect(updated.amount == 200)
        #expect(updated.createdAt == created.createdAt)
        #expect(updated.updatedAt == fixture.clock.now)
        #expect(try await fixture.database.operations.operation(created.id) == updated)

        draft.note = nil
        let cleared = try await fixture.database.operations.update(created.id, with: draft)
        #expect(cleared.note == nil)
    }

    @Test func deletesOperation() async throws {
        let fixture = try await Fixture()
        let created = try await fixture.addOperation(.expense, amount: 100, on: "2026-10-30")

        try await fixture.database.operations.delete(created.id)
        #expect(try await fixture.database.operations.operation(created.id) == nil)

        await #expect(throws: RepositoryError.notFound) {
            try await fixture.database.operations.delete(created.id)
        }
    }

    // MARK: Vincoli

    @Test func rejectsKindDifferentFromCategory() async throws {
        let fixture = try await Fixture()
        let draft = OperationDraft(
            kind: .income,
            amount: 100,
            date: try #require(Day(string: "2026-10-30")),
            accountID: fixture.account.id,
            categoryID: fixture.expenseCategory.id
        )
        await #expect(throws: RepositoryError.kindMismatch) {
            try await fixture.database.operations.create(draft)
        }

        let existing = try await fixture.addOperation(.expense, amount: 100, on: "2026-10-30")
        await #expect(throws: RepositoryError.kindMismatch) {
            try await fixture.database.operations.update(existing.id, with: draft)
        }
    }

    @Test func rejectsInvalidDraftAndMissingReferences() async throws {
        let fixture = try await Fixture()
        let day = try #require(Day(string: "2026-10-30"))

        await #expect(throws: OperationDraftError.amountNotPositive) {
            try await fixture.database.operations.create(OperationDraft(
                kind: .expense, amount: 0, date: day,
                accountID: fixture.account.id, categoryID: fixture.expenseCategory.id
            ))
        }
        await #expect(throws: RepositoryError.notFound) {
            try await fixture.database.operations.create(OperationDraft(
                kind: .expense, amount: 100, date: day,
                accountID: AccountID(), categoryID: fixture.expenseCategory.id
            ))
        }
        await #expect(throws: RepositoryError.notFound) {
            try await fixture.database.operations.update(OperationID(), with: OperationDraft(
                kind: .expense, amount: 100, date: day,
                accountID: fixture.account.id, categoryID: fixture.expenseCategory.id
            ))
        }
    }

    // MARK: Metadati

    @Test func everyWriteUpdatesMetadata() async throws {
        let fixture = try await Fixture()
        fixture.clock.advance(by: 10)
        let created = try await fixture.addOperation(.expense, amount: 100, on: "2026-10-30")
        #expect(try fixture.database.metadata().lastModifiedAt == fixture.clock.now)
        #expect(try fixture.database.metadata().lastModifiedBy == "Test")

        fixture.clock.advance(by: 10)
        try await fixture.database.operations.delete(created.id)
        #expect(try fixture.database.metadata().lastModifiedAt == fixture.clock.now)
    }

    @Test func failedWriteDoesNotTouchMetadata() async throws {
        let fixture = try await Fixture()
        let before = try fixture.database.metadata()
        fixture.clock.advance(by: 10)
        await #expect(throws: RepositoryError.notFound) {
            try await fixture.database.operations.delete(OperationID())
        }
        #expect(try fixture.database.metadata() == before)
    }

    // MARK: Aggregati

    @Test func monthlyTotalsIncludeFirstAndLastDayOnly() async throws {
        let fixture = try await Fixture()
        try await fixture.addOperation(.expense, amount: 1, on: "2026-09-30")
        try await fixture.addOperation(.expense, amount: 10, on: "2026-10-01")
        try await fixture.addOperation(.expense, amount: 100, on: "2026-10-31")
        try await fixture.addOperation(.income, amount: 1000, on: "2026-10-15")
        try await fixture.addOperation(.expense, amount: 10000, on: "2026-11-01")

        let totals = try await fixture.database.operations
            .observeTotals(for: try #require(YearMonth(year: 2026, month: 10)))
            .firstValue()
        #expect(totals == PeriodTotals(income: 1000, expense: 110))
        #expect(totals?.balance == 890)
    }

    @Test func leapYearFebruaryIncludesTheTwentyNinth() async throws {
        let fixture = try await Fixture()
        try await fixture.addOperation(.expense, amount: 5, on: "2024-02-29")
        try await fixture.addOperation(.expense, amount: 7, on: "2024-03-01")

        let totals = try await fixture.database.operations
            .observeTotals(for: try #require(YearMonth(year: 2024, month: 2)))
            .firstValue()
        #expect(totals == PeriodTotals(income: 0, expense: 5))
    }

    @Test func monthWithoutOperationsIsZero() async throws {
        let fixture = try await Fixture()
        let totals = try await fixture.database.operations
            .observeTotals(for: try #require(YearMonth(year: 2026, month: 1)))
            .firstValue()
        #expect(totals == PeriodTotals())
    }

    @Test func groupsByMonthSkippingEmptyOnes() async throws {
        let fixture = try await Fixture()
        try await fixture.addOperation(.expense, amount: 10, on: "2025-12-31")
        try await fixture.addOperation(.income, amount: 20, on: "2026-01-01")
        try await fixture.addOperation(.expense, amount: 30, on: "2026-03-15")
        try await fixture.addOperation(.expense, amount: 40, on: "2026-03-16")

        let all = try #require(try await fixture.database.operations.observeMonthlyTotals(year: nil).firstValue())
        #expect(all.map(\.month.string) == ["2026-03", "2026-01", "2025-12"])
        #expect(all.first?.totals == PeriodTotals(income: 0, expense: 70))

        let only2026 = try #require(try await fixture.database.operations.observeMonthlyTotals(year: 2026).firstValue())
        #expect(only2026.map(\.month.string) == ["2026-03", "2026-01"])
    }

    @Test func groupsByYear() async throws {
        let fixture = try await Fixture()
        try await fixture.addOperation(.expense, amount: 10, on: "2025-06-01")
        try await fixture.addOperation(.income, amount: 20, on: "2026-01-01")
        try await fixture.addOperation(.expense, amount: 5, on: "2026-12-31")

        let years = try #require(try await fixture.database.operations.observeYearlyTotals().firstValue())
        #expect(years == [
            YearTotals(year: 2026, totals: PeriodTotals(income: 20, expense: 5)),
            YearTotals(year: 2025, totals: PeriodTotals(income: 0, expense: 10)),
        ])
    }

    // MARK: Elenchi

    @Test func recentAreOrderedByDateThenCreation() async throws {
        let fixture = try await Fixture()
        let old = try await fixture.addOperation(.expense, amount: 1, on: "2026-10-01")
        fixture.clock.advance(by: 1)
        let firstToday = try await fixture.addOperation(.expense, amount: 2, on: "2026-10-30")
        fixture.clock.advance(by: 1)
        let secondToday = try await fixture.addOperation(.income, amount: 3, on: "2026-10-30")
        fixture.clock.advance(by: 1)
        _ = try await fixture.addOperation(.expense, amount: 4, on: "2026-09-01")

        let recent = try #require(try await fixture.database.operations.observeRecent(limit: 3).firstValue())
        #expect(recent.map(\.id) == [secondToday.id, firstToday.id, old.id])
    }

    @Test func itemsCarryCategoryAndAccount() async throws {
        let fixture = try await Fixture()
        let created = try await fixture.addOperation(.expense, amount: 100, on: "2026-10-30")

        let item = try #require(try await fixture.database.operations.observeItem(created.id).firstValue() ?? nil)
        #expect(item.operation == created)
        #expect(item.category == fixture.expenseCategory)
        #expect(item.accountName == fixture.account.name)
    }

    @Test func filtersByMonthKindCategoryAndAccount() async throws {
        let fixture = try await Fixture()
        let october = try await fixture.addOperation(.expense, amount: 1, on: "2026-10-10")
        let income = try await fixture.addOperation(.income, amount: 2, on: "2026-10-11")
        let november = try await fixture.addOperation(.expense, amount: 3, on: "2026-11-01")
        let operations = fixture.database.operations

        let byMonth = try #require(try await operations.observeItems(
            OperationQuery(month: YearMonth(year: 2026, month: 10))
        ).firstValue())
        #expect(Set(byMonth.map(\.id)) == [october.id, income.id])

        let byKind = try #require(try await operations.observeItems(OperationQuery(kind: .income)).firstValue())
        #expect(byKind.map(\.id) == [income.id])

        let byCategory = try #require(try await operations.observeItems(
            OperationQuery(categoryID: fixture.expenseCategory.id)
        ).firstValue())
        #expect(Set(byCategory.map(\.id)) == [october.id, november.id])

        let byAccount = try #require(try await operations.observeItems(OperationQuery(accountID: AccountID())).firstValue())
        #expect(byAccount.isEmpty)
    }

    @Test func searchesNoteAndCategoryName() async throws {
        let fixture = try await Fixture()
        let coffee = try await fixture.addOperation(.expense, amount: 1, on: "2026-10-10", note: "Caffè al bar")
        let salary = try await fixture.addOperation(.income, amount: 2, on: "2026-10-11")
        let operations = fixture.database.operations

        let byNote = try #require(try await operations.observeItems(OperationQuery(searchText: "caff")).firstValue())
        #expect(byNote.map(\.id) == [coffee.id])

        let byCategory = try #require(try await operations.observeItems(
            OperationQuery(searchText: fixture.incomeCategory.name)
        ).firstValue())
        #expect(byCategory.map(\.id) == [salary.id])

        let blank = try #require(try await operations.observeItems(OperationQuery(searchText: "   ")).firstValue())
        #expect(blank.count == 2)
    }

    @Test func searchTreatsWildcardsLiterally() async throws {
        let fixture = try await Fixture()
        let discount = try await fixture.addOperation(.expense, amount: 1, on: "2026-10-10", note: "sconto 20%")
        try await fixture.addOperation(.expense, amount: 2, on: "2026-10-11", note: "sconto 200")
        try await fixture.addOperation(.expense, amount: 3, on: "2026-10-12", note: "a_b")

        let percent = try #require(try await fixture.database.operations.observeItems(
            OperationQuery(searchText: "20%")
        ).firstValue())
        #expect(percent.map(\.id) == [discount.id])

        let underscore = try #require(try await fixture.database.operations.observeItems(
            OperationQuery(searchText: "_")
        ).firstValue())
        #expect(underscore.count == 1)
    }

    @Test func paginatesWithoutOverlaps() async throws {
        let fixture = try await Fixture()
        for day in 1...5 {
            try await fixture.addOperation(.expense, amount: Int64(day), on: String(format: "2026-10-%02d", day))
        }

        let operations = fixture.database.operations
        let first = try #require(try await operations.observeItems(OperationQuery(limit: 2)).firstValue())
        let second = try #require(try await operations.observeItems(OperationQuery(limit: 2, offset: 2)).firstValue())
        let third = try #require(try await operations.observeItems(OperationQuery(limit: 2, offset: 4)).firstValue())

        #expect((first + second + third).map(\.operation.amount) == [5, 4, 3, 2, 1])
    }

    // MARK: Osservazione

    @Test func observationEmitsAfterEveryChange() async throws {
        let fixture = try await Fixture()
        let month = try #require(YearMonth(year: 2026, month: 10))
        var iterator = fixture.database.operations.observeTotals(for: month).makeAsyncIterator()

        var totals = try await iterator.next()
        #expect(totals == PeriodTotals())

        let created = try await fixture.addOperation(.expense, amount: 100, on: "2026-10-30")
        totals = try await iterator.next()
        #expect(totals == PeriodTotals(income: 0, expense: 100))

        var draft = OperationDraft(
            kind: .expense,
            amount: 250,
            date: created.date,
            accountID: created.accountID,
            categoryID: created.categoryID
        )
        try await fixture.database.operations.update(created.id, with: draft)
        totals = try await iterator.next()
        #expect(totals == PeriodTotals(income: 0, expense: 250))

        draft.date = try #require(Day(string: "2026-11-01"))
        try await fixture.database.operations.update(created.id, with: draft)
        totals = try await iterator.next()
        #expect(totals == PeriodTotals())
    }

    @Test func listObservationSeesCategoryRename() async throws {
        let fixture = try await Fixture()
        try await fixture.addOperation(.expense, amount: 100, on: "2026-10-30")
        var iterator = fixture.database.operations.observeRecent(limit: 3).makeAsyncIterator()
        _ = try await iterator.next()

        try await fixture.database.categories.update(
            fixture.expenseCategory.id, name: "Abitazione", symbol: "house", color: .brown
        )
        let items = try await iterator.next()
        #expect(items?.first?.category.name == "Abitazione")
    }
}
