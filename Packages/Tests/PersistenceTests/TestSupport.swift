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
}

extension AsyncThrowingStream {
    /// Primo valore emesso: il valore attuale al momento dell'osservazione.
    func firstValue() async throws -> Element? {
        try await first { _ in true }
    }
}
