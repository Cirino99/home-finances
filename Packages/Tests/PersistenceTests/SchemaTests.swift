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

    @Test func migrationCreatesTransferTable() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.read { db in
            #expect(try db.tableExists("transfer"))
            let indexes = try db.indexes(on: "transfer").map(\.name)
            for index in ["idx_transfer_date", "idx_transfer_from", "idx_transfer_to"] {
                #expect(indexes.contains(index), "Manca l'indice \(index)")
            }
        }
        #expect(AppDatabase.migrator.migrations == ["v1", "v2"])
    }

    @Test func databaseEnforcesTransferChecks() async throws {
        let fixture = try await Fixture()
        let other = try await fixture.addAccount()
        let insert = """
            INSERT INTO transfer (id, amount, currency, date, from_account_id, to_account_id, created_at, updated_at)
            VALUES (?, ?, 'EUR', '2026-11-07', ?, ?, 'x', 'x')
            """
        let cases: [(Int64, AccountID, AccountID)] = [
            (0, fixture.account.id, other.id),
            (-1, fixture.account.id, other.id),
            (100, fixture.account.id, fixture.account.id),
            (100, fixture.account.id, AccountID()),
        ]
        for (amount, from, to) in cases {
            #expect(throws: DatabaseError.self) {
                try fixture.execute(insert, arguments: [UUID().uuidString, amount, from.databaseValue, to.databaseValue])
            }
        }
    }

    @Test func transfersRestrictAccountDeletion() async throws {
        let fixture = try await Fixture()
        let from = try await fixture.addAccount("Da")
        let to = try await fixture.addAccount("A")
        try await fixture.addTransfer(amount: 100, on: "2026-11-07", from: from, to: to)

        for account in [from, to] {
            #expect(throws: DatabaseError.self) {
                try fixture.execute("DELETE FROM account WHERE id = ?", arguments: [account.id.databaseValue])
            }
        }
    }

    /// Un database creato dalla versione precedente si aggiorna all'apertura senza perdere dati.
    @Test func migratesVersion1DatabaseKeepingData() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "SchemaTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: AppDatabase.fileName)

        let queue = try DatabaseQueue(path: url.path)
        try AppDatabase.migrator.migrate(queue, upTo: "v1")
        try queue.inDatabase { db in
            try Version1Data.insert(operations: 2, in: db)
        }
        try queue.close()

        let database = try AppDatabase.open(at: url)
        let applied = try await database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        #expect(applied == ["v1", "v2"])
        #expect(try await database.operations.allItems().count == 2)
        #expect(try await database.movements.allMovements().count == 2)

        let balances = try #require(try await database.movements.observeBalances().firstValue())
        #expect(balances.map(\.balance) == [-200])
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
