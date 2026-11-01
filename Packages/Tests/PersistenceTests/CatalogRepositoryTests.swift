import Core
import Foundation
import Testing
@testable import Persistence

struct CatalogRepositoryTests {
    // MARK: Categorie

    @Test func createsCategoryAtTheEnd() async throws {
        let fixture = try await Fixture()
        let created = try await fixture.database.categories.create(
            name: "  Viaggi ", kind: .expense, symbol: "airplane", color: .teal
        )
        #expect(created.name == "Viaggi")

        let all = try #require(try await fixture.database.categories.observeCategories(includingArchived: false).firstValue())
        #expect(all.last == created)
    }

    @Test func rejectsEmptyNames() async throws {
        let fixture = try await Fixture()
        await #expect(throws: RepositoryError.nameEmpty) {
            try await fixture.database.categories.create(name: "  ", kind: .expense, symbol: "x", color: .gray)
        }
        await #expect(throws: RepositoryError.nameEmpty) {
            try await fixture.database.accounts.create(name: "", currency: "EUR", initialBalance: 0)
        }
    }

    @Test func updatesCategoryWithoutChangingKind() async throws {
        let fixture = try await Fixture()
        try await fixture.database.categories.update(
            fixture.expenseCategory.id, name: "Abitazione", symbol: "building", color: .blue
        )
        let all = try #require(try await fixture.database.categories.observeCategories(includingArchived: false).firstValue())
        let updated = try #require(all.first { $0.id == fixture.expenseCategory.id })
        #expect(updated.name == "Abitazione")
        #expect(updated.symbol == "building")
        #expect(updated.color == .blue)
        #expect(updated.kind == fixture.expenseCategory.kind)

        await #expect(throws: RepositoryError.notFound) {
            try await fixture.database.categories.update(CategoryID(), name: "x", symbol: "x", color: .gray)
        }
    }

    @Test func removingUnusedCategoryDeletesIt() async throws {
        let fixture = try await Fixture()
        #expect(try await fixture.database.categories.remove(fixture.expenseCategory.id) == .deleted)

        let all = try #require(try await fixture.database.categories.observeCategories(includingArchived: true).firstValue())
        #expect(!all.contains { $0.id == fixture.expenseCategory.id })
    }

    @Test func removingUsedCategoryArchivesIt() async throws {
        let fixture = try await Fixture()
        let operation = try await fixture.addOperation(.expense, amount: 100, on: "2026-10-30")

        #expect(try await fixture.database.categories.remove(fixture.expenseCategory.id) == .archived)

        let visible = try #require(try await fixture.database.categories.observeCategories(includingArchived: false).firstValue())
        #expect(!visible.contains { $0.id == fixture.expenseCategory.id })
        let all = try #require(try await fixture.database.categories.observeCategories(includingArchived: true).firstValue())
        #expect(all.first { $0.id == fixture.expenseCategory.id }?.isArchived == true)

        // L'operazione resta leggibile con la sua categoria archiviata.
        let item = try #require(try await fixture.database.operations.observeItem(operation.id).firstValue() ?? nil)
        #expect(item.category.isArchived)
    }

    @Test func removingMissingRowsThrows() async throws {
        let fixture = try await Fixture()
        await #expect(throws: RepositoryError.notFound) {
            try await fixture.database.categories.remove(CategoryID())
        }
        await #expect(throws: RepositoryError.notFound) {
            try await fixture.database.accounts.remove(AccountID())
        }
    }

    @Test func reordersCategories() async throws {
        let fixture = try await Fixture()
        let before = try #require(try await fixture.database.categories.observeCategories(includingArchived: false).firstValue())
        let reversed = Array(before.map(\.id).reversed())

        try await fixture.database.categories.reorder(reversed)

        let after = try #require(try await fixture.database.categories.observeCategories(includingArchived: false).firstValue())
        #expect(after.map(\.id) == reversed)
    }

    @Test func archivesAndRestoresCategory() async throws {
        let fixture = try await Fixture()
        let categories = fixture.database.categories
        try await categories.setArchived(fixture.expenseCategory.id, isArchived: true)
        var visible = try #require(try await categories.observeCategories(includingArchived: false).firstValue())
        #expect(!visible.contains { $0.id == fixture.expenseCategory.id })

        try await categories.setArchived(fixture.expenseCategory.id, isArchived: false)
        visible = try #require(try await categories.observeCategories(includingArchived: false).firstValue())
        #expect(visible.contains { $0.id == fixture.expenseCategory.id })
    }

    // MARK: Conti

    @Test func managesAccounts() async throws {
        let fixture = try await Fixture()
        let accounts = fixture.database.accounts
        let savings = try await accounts.create(name: "Risparmi", currency: "EUR", initialBalance: -500)
        #expect(savings.initialBalance == -500)

        try await accounts.update(savings.id, name: "Deposito", initialBalance: 1000)
        var all = try #require(try await accounts.observeAccounts(includingArchived: false).firstValue())
        #expect(all.map(\.name) == [DefaultData.accountName, "Deposito"])
        #expect(all.last?.initialBalance == 1000)

        try await accounts.reorder([savings.id, fixture.account.id])
        all = try #require(try await accounts.observeAccounts(includingArchived: false).firstValue())
        #expect(all.first?.id == savings.id)

        #expect(try await accounts.remove(savings.id) == .deleted)
    }

    @Test func removingUsedAccountArchivesIt() async throws {
        let fixture = try await Fixture()
        try await fixture.addOperation(.expense, amount: 100, on: "2026-10-30")
        let other = try await fixture.database.accounts.create(name: "Altro", currency: "EUR", initialBalance: 0)

        #expect(try await fixture.database.accounts.remove(fixture.account.id) == .archived)
        let visible = try #require(try await fixture.database.accounts.observeAccounts(includingArchived: false).firstValue())
        #expect(visible.map(\.id) == [other.id])
    }

    @Test func lastActiveAccountCannotDisappear() async throws {
        let fixture = try await Fixture()
        let accounts = fixture.database.accounts

        await #expect(throws: RepositoryError.lastActiveAccount) {
            try await accounts.remove(fixture.account.id)
        }
        await #expect(throws: RepositoryError.lastActiveAccount) {
            try await accounts.setArchived(fixture.account.id, isArchived: true)
        }

        let other = try await accounts.create(name: "Altro", currency: "EUR", initialBalance: 0)
        try await accounts.setArchived(other.id, isArchived: true)
        await #expect(throws: RepositoryError.lastActiveAccount) {
            try await accounts.remove(fixture.account.id)
        }

        // Un conto già archiviato si può sempre togliere, e ripristinare non è mai un problema.
        #expect(try await accounts.remove(other.id) == .deleted)
        try await accounts.setArchived(fixture.account.id, isArchived: false)
    }

    @Test func seedDoesNotRepeatAfterAccountChanges() async throws {
        let fixture = try await Fixture()
        // Cancellare a mano l'unico conto non deve far ripartire i dati iniziali.
        try fixture.execute("DELETE FROM account")

        #expect(try fixture.database.isSeeded())
        try await fixture.database.seedIfNeeded(currency: "USD")

        let categories = try #require(try await fixture.database.categories.observeCategories(includingArchived: true).firstValue())
        #expect(categories.count == DefaultData.categories.count, "Le categorie non si duplicano")
    }

    @Test func catalogWritesUpdateMetadata() async throws {
        let fixture = try await Fixture()
        fixture.clock.advance(by: 10)
        try await fixture.database.categories.create(name: "Viaggi", kind: .expense, symbol: "airplane", color: .teal)
        #expect(try fixture.database.metadata().lastModifiedAt == fixture.clock.now)

        fixture.clock.advance(by: 10)
        let other = try await fixture.database.accounts.create(name: "Altro", currency: "EUR", initialBalance: 0)
        try await fixture.database.accounts.setArchived(other.id, isArchived: true)
        #expect(try fixture.database.metadata().lastModifiedAt == fixture.clock.now)
    }
}
