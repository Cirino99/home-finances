import Core
import Foundation
import GRDB
import Synchronization
import Testing
@testable import Persistence

final class TestClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    var now: Date { current.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 += seconds }
    }
}

/// Database in memoria con i dati iniziali e scorciatoie per i test.
struct Fixture {
    let clock = TestClock()
    let database: AppDatabase
    let account: Account
    let expenseCategory: OperationCategory
    let incomeCategory: OperationCategory

    init() async throws {
        database = try AppDatabase.inMemory(deviceName: "Test") { [clock] in clock.now }
        try await database.seedIfNeeded(currency: "EUR")

        let accounts = database.accounts.observeAccounts(includingArchived: true)
        account = try #require(try await accounts.first { _ in true }?.first)

        let categories = try #require(
            try await database.categories.observeCategories(includingArchived: true).first { _ in true }
        )
        expenseCategory = try #require(categories.first { $0.kind == .expense })
        incomeCategory = try #require(categories.first { $0.kind == .income })
    }

    /// SQL diretto, per verificare i vincoli dello schema aggirando i repository.
    func execute(_ sql: String, arguments: StatementArguments = StatementArguments()) throws {
        try database.writer.write { db in
            try db.execute(sql: sql, arguments: arguments)
        }
    }

    /// Lettura sincrona: permette di restituire `Row`, che non è `Sendable`.
    func read<Value>(_ fetch: (Database) throws -> Value) throws -> Value {
        try database.writer.read(fetch)
    }

    @discardableResult
    func addOperation(
        _ kind: OperationKind,
        amount: Int64,
        on date: String,
        note: String? = nil
    ) async throws -> FinanceOperation {
        try await database.operations.create(OperationDraft(
            kind: kind,
            amount: amount,
            date: try #require(Day(string: date)),
            accountID: account.id,
            categoryID: kind == .expense ? expenseCategory.id : incomeCategory.id,
            note: note
        ))
    }

    /// Operazione su un conto diverso da quello iniziale.
    @discardableResult
    func addOperation(
        _ kind: OperationKind,
        amount: Int64,
        on date: String,
        account: Account
    ) async throws -> FinanceOperation {
        try await database.operations.create(OperationDraft(
            kind: kind,
            amount: amount,
            date: try #require(Day(string: date)),
            accountID: account.id,
            categoryID: kind == .expense ? expenseCategory.id : incomeCategory.id
        ))
    }

    func addAccount(
        _ name: String = "Risparmi",
        currency: String = "EUR",
        initialBalance: Int64 = 0
    ) async throws -> Account {
        try await database.accounts.create(name: name, currency: currency, initialBalance: initialBalance)
    }

    @discardableResult
    func addTransfer(
        amount: Int64,
        on date: String,
        from: Account,
        to: Account,
        note: String? = nil
    ) async throws -> AccountTransfer {
        try await database.transfers.create(TransferDraft(
            amount: amount,
            date: try #require(Day(string: date)),
            fromAccountID: from.id,
            toAccountID: to.id,
            note: note
        ))
    }

    func movements(_ query: MovementQuery = MovementQuery()) async throws -> [MovementListItem] {
        try #require(try await database.movements.observeMovements(query).firstValue())
    }

    func balances() async throws -> [AccountBalance] {
        try #require(try await database.movements.observeBalances().firstValue())
    }
}

extension AsyncThrowingStream {
    /// Primo valore emesso: il valore attuale al momento dell'osservazione.
    func firstValue() async throws -> Element? {
        try await first { _ in true }
    }
}

/// Dati scritti come li avrebbe scritti la versione con la sola migrazione `v1`: un conto,
/// una categoria di uscita e `operations` uscite da 1 euro a gennaio 2026.
enum Version1Data {
    static let timestamp = "2026-01-01T00:00:00.000Z"

    static func insert(operations: Int, in db: Database) throws {
        let accountID = UUID().uuidString
        let categoryID = UUID().uuidString
        try db.execute(
            sql: "INSERT INTO app_metadata (key, value) VALUES ('seeded_at', ?)",
            arguments: [timestamp]
        )
        try db.execute(
            sql: """
                INSERT INTO account (id, name, currency, created_at, updated_at)
                VALUES (?, 'Conto principale', 'EUR', ?, ?)
                """,
            arguments: [accountID, timestamp, timestamp]
        )
        try db.execute(
            sql: """
                INSERT INTO category (id, name, kind, symbol, color, created_at, updated_at)
                VALUES (?, 'Spesa', 'expense', 'cart', 'green', ?, ?)
                """,
            arguments: [categoryID, timestamp, timestamp]
        )
        for day in 0..<operations {
            try db.execute(
                sql: """
                    INSERT INTO operation (id, kind, amount, currency, date, account_id, category_id, created_at, updated_at)
                    VALUES (?, 'expense', 100, 'EUR', ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString, String(format: "2026-01-%02d", day + 1),
                    accountID, categoryID, timestamp, timestamp,
                ]
            )
        }
    }
}
