import Core
import Foundation
import GRDB

/// Trasferimenti tra conti (§ 6.2, § 8.8).
struct GRDBTransferRepository: TransferRepository {
    let database: AppDatabase

    // MARK: Scritture

    func create(_ draft: TransferDraft) async throws -> AccountTransfer {
        try draft.validate()
        let id = TransferID()
        let date = database.now()
        let timestamp = Timestamp.string(date)
        return try await database.writer.write { [database] db in
            let currency = try checkAccounts(of: draft, in: db)
            try db.execute(
                sql: """
                    INSERT INTO transfer
                    (id, amount, currency, date, from_account_id, to_account_id, note, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    id.databaseValue, draft.amount, currency, draft.date.string,
                    draft.fromAccountID.databaseValue, draft.toAccountID.databaseValue, draft.normalizedNote,
                    timestamp, timestamp,
                ]
            )
            try database.touchMetadata(db, timestamp: timestamp)
            return AccountTransfer(
                id: id,
                amount: draft.amount,
                currency: currency,
                date: draft.date,
                fromAccountID: draft.fromAccountID,
                toAccountID: draft.toAccountID,
                note: draft.normalizedNote,
                createdAt: date,
                updatedAt: date
            )
        }
    }

    func update(_ id: TransferID, with draft: TransferDraft) async throws -> AccountTransfer {
        try draft.validate()
        let date = database.now()
        let timestamp = Timestamp.string(date)
        return try await database.writer.write { [database] db in
            guard let existing = try fetchTransfer(id, in: db) else { throw RepositoryError.notFound }
            let currency = try checkAccounts(of: draft, in: db)
            try db.execute(
                sql: """
                    UPDATE transfer
                    SET amount = ?, currency = ?, date = ?, from_account_id = ?, to_account_id = ?, note = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    draft.amount, currency, draft.date.string,
                    draft.fromAccountID.databaseValue, draft.toAccountID.databaseValue, draft.normalizedNote,
                    timestamp, id.databaseValue,
                ]
            )
            try database.touchMetadata(db, timestamp: timestamp)
            return AccountTransfer(
                id: id,
                amount: draft.amount,
                currency: currency,
                date: draft.date,
                fromAccountID: draft.fromAccountID,
                toAccountID: draft.toAccountID,
                note: draft.normalizedNote,
                createdAt: existing.createdAt,
                updatedAt: date
            )
        }
    }

    func delete(_ id: TransferID) async throws {
        let timestamp = Timestamp.string(database.now())
        try await database.writer.write { [database] db in
            try db.execute(sql: "DELETE FROM transfer WHERE id = ?", arguments: [id.databaseValue])
            guard db.changesCount > 0 else { throw RepositoryError.notFound }
            try database.touchMetadata(db, timestamp: timestamp)
        }
    }

    func transfer(_ id: TransferID) async throws -> AccountTransfer? {
        try await database.writer.read { db in
            try fetchTransfer(id, in: db)
        }
    }

    // MARK: Letture reattive

    func observeItem(_ id: TransferID) -> AsyncThrowingStream<TransferListItem?, any Error> {
        database.observe { db in
            try Row.fetchOne(db, sql: "\(Self.itemSelect) WHERE t.id = ?", arguments: [id.databaseValue])
                .map(TransferListItem.init(row:))
        }
    }

    // MARK: Supporto

    static let itemSelect = """
        SELECT t.*, fa.name AS from_account_name, ta.name AS to_account_name
        FROM transfer t
        JOIN account fa ON fa.id = t.from_account_id
        JOIN account ta ON ta.id = t.to_account_id
        """

    /// Verifica che i due conti esistano e abbiano la stessa valuta. Restituisce la valuta.
    /// Un conto archiviato è ammesso: in modifica un trasferimento vecchio può restare dov'è (§ 8.8).
    private func checkAccounts(of draft: TransferDraft, in db: Database) throws -> String {
        guard let fromCurrency = try String.fetchOne(
            db, sql: "SELECT currency FROM account WHERE id = ?", arguments: [draft.fromAccountID.databaseValue]
        ), let toCurrency = try String.fetchOne(
            db, sql: "SELECT currency FROM account WHERE id = ?", arguments: [draft.toAccountID.databaseValue]
        ) else {
            throw RepositoryError.notFound
        }
        guard fromCurrency == toCurrency else { throw RepositoryError.currencyMismatch }
        return fromCurrency
    }

    private func fetchTransfer(_ id: TransferID, in db: Database) throws -> AccountTransfer? {
        try Row.fetchOne(db, sql: "SELECT * FROM transfer WHERE id = ?", arguments: [id.databaseValue])
            .map(AccountTransfer.init(row:))
    }
}
