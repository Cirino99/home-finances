import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

struct SchemaTests {
    @Test func migrationCreatesTablesAndIndexes() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.read { db in
            for table in ["account", "category", "operation", "app_metadata"] {
                #expect(try db.tableExists(table), "Manca la tabella \(table)")
            }
            let indexes = try db.indexes(on: "operation").map(\.name)
            for index in ["idx_operation_date", "idx_operation_category", "idx_operation_account"] {
                #expect(indexes.contains(index), "Manca l'indice \(index)")
            }
        }
    }

    @Test func migrationGeneratesDatabaseID() throws {
        let first = try AppDatabase.inMemory().metadata()
        let second = try AppDatabase.inMemory().metadata()
        #expect(UUID(uuidString: first.databaseID) != nil)
        #expect(first.databaseID != second.databaseID)
        #expect(first.lastModifiedAt == nil)
    }

    @Test func seedInsertsDefaultDataOnce() async throws {
        let database = try AppDatabase.inMemory()
        #expect(try !database.isSeeded())

        try await database.seedIfNeeded(currency: "EUR")
        try await database.seedIfNeeded(currency: "USD")
        #expect(try database.isSeeded())

        let accounts = try #require(try await database.accounts.observeAccounts(includingArchived: true).firstValue())
        #expect(accounts.map(\.name) == [DefaultData.accountName])
        #expect(accounts.first?.currency == "EUR", "Il secondo seed non deve cambiare nulla")

        let categories = try #require(try await database.categories.observeCategories(includingArchived: true).firstValue())
        #expect(categories.map(\.name) == DefaultData.categories.map(\.name))
        #expect(categories.map(\.kind) == DefaultData.categories.map(\.kind))
    }

    @Test(arguments: ["", "eur", "EURO", "E1R"])
    func seedRejectsInvalidCurrency(currency: String) async throws {
        let database = try AppDatabase.inMemory()
        await #expect(throws: PersistenceError.invalidCurrency(currency)) {
            try await database.seedIfNeeded(currency: currency)
        }
        #expect(try !database.isSeeded())
    }

    @Test func databaseEnforcesAmountAndKindChecks() async throws {
        let fixture = try await Fixture()
        let insert = """
            INSERT INTO operation (id, kind, amount, currency, date, account_id, category_id, created_at, updated_at)
            VALUES (?, ?, ?, 'EUR', '2026-10-30', ?, ?, 'x', 'x')
            """
        for (kind, amount) in [("expense", 0), ("expense", -1), ("other", 100)] {
            #expect(throws: DatabaseError.self) {
                try fixture.execute(insert, arguments: [
                    UUID().uuidString, kind, amount,
                    fixture.account.id.databaseValue, fixture.expenseCategory.id.databaseValue,
                ])
            }
        }
    }

    @Test func foreignKeysRestrictDeletion() async throws {
        let fixture = try await Fixture()
        try await fixture.addOperation(.expense, amount: 100, on: "2026-10-30")

        for (table, id) in [
            ("account", fixture.account.id.databaseValue),
            ("category", fixture.expenseCategory.id.databaseValue),
        ] {
            #expect(throws: DatabaseError.self) {
                try fixture.execute("DELETE FROM \(table) WHERE id = ?", arguments: [id])
            }
        }
    }

    @Test func idsAreStoredAsText() async throws {
        let fixture = try await Fixture()
        let operation = try await fixture.addOperation(.expense, amount: 100, on: "2026-10-30")
        let row = try #require(try fixture.read { db in
            try Row.fetchOne(db, sql: "SELECT typeof(id) AS id_type, id, date, created_at FROM operation")
        })
        let idType: String = row["id_type"]
        let id: String = row["id"]
        let date: String = row["date"]
        let createdAt: String = row["created_at"]
        #expect(idType == "text")
        #expect(id == operation.id.rawValue.uuidString)
        #expect(date == "2026-10-30")
        #expect(createdAt.hasSuffix("Z"), "Timestamp in UTC")
    }
}
