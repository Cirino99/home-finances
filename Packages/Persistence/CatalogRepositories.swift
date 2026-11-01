import Core
import Foundation
import GRDB

/// Categorie: si archiviano invece di essere cancellate, se hanno operazioni collegate (§ 6.1).
struct GRDBCategoryRepository: CategoryRepository {
    let database: AppDatabase

    func create(name: String, kind: OperationKind, symbol: String, color: CategoryColor) async throws -> OperationCategory {
        let name = try validName(name)
        let id = CategoryID()
        let date = database.now()
        let timestamp = Timestamp.string(date)
        return try await database.writer.write { [database] db in
            let sortOrder = try nextSortOrder(table: "category", in: db)
            try db.execute(
                sql: """
                    INSERT INTO category (id, name, kind, symbol, color, sort_order, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [id.databaseValue, name, kind.rawValue, symbol, color.rawValue, sortOrder, timestamp, timestamp]
            )
            try database.touchMetadata(db, timestamp: timestamp)
            return OperationCategory(
                id: id, name: name, kind: kind, symbol: symbol, color: color,
                isArchived: false, sortOrder: sortOrder, createdAt: date, updatedAt: date
            )
        }
    }

    func update(_ id: CategoryID, name: String, symbol: String, color: CategoryColor) async throws {
        let name = try validName(name)
        try await updateRow(database: database) { db, timestamp in
            try db.execute(
                sql: "UPDATE category SET name = ?, symbol = ?, color = ?, updated_at = ? WHERE id = ?",
                arguments: [name, symbol, color.rawValue, timestamp, id.databaseValue]
            )
        }
    }

    func setArchived(_ id: CategoryID, isArchived: Bool) async throws {
        try await setArchivedFlag(id, isArchived: isArchived, table: "category", database: database)
    }

    func reorder(_ ids: [CategoryID]) async throws {
        try await reorderRows(ids, table: "category", database: database)
    }

    func remove(_ id: CategoryID) async throws -> RemovalOutcome {
        try await removeRow(id, table: "category", foreignKey: "category_id", database: database)
    }

    func observeCategories(includingArchived: Bool) -> AsyncThrowingStream<[OperationCategory], any Error> {
        database.observe { db in
            let filter = includingArchived ? "" : "WHERE is_archived = 0"
            return try Row.fetchAll(db, sql: "SELECT * FROM category \(filter) ORDER BY sort_order, created_at")
                .map { try OperationCategory(row: $0) }
        }
    }
}

/// Conti: stesse regole delle categorie (§ 8.6).
struct GRDBAccountRepository: AccountRepository {
    let database: AppDatabase

    func create(name: String, currency: String, initialBalance: Int64) async throws -> Account {
        let name = try validName(name)
        let id = AccountID()
        let date = database.now()
        let timestamp = Timestamp.string(date)
        return try await database.writer.write { [database] db in
            let sortOrder = try nextSortOrder(table: "account", in: db)
            try db.execute(
                sql: """
                    INSERT INTO account (id, name, currency, initial_balance, sort_order, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [id.databaseValue, name, currency, initialBalance, sortOrder, timestamp, timestamp]
            )
            try database.touchMetadata(db, timestamp: timestamp)
            return Account(
                id: id, name: name, currency: currency, initialBalance: initialBalance,
                isArchived: false, sortOrder: sortOrder, createdAt: date, updatedAt: date
            )
        }
    }

    func update(_ id: AccountID, name: String, initialBalance: Int64) async throws {
        let name = try validName(name)
        try await updateRow(database: database) { db, timestamp in
            try db.execute(
                sql: "UPDATE account SET name = ?, initial_balance = ?, updated_at = ? WHERE id = ?",
                arguments: [name, initialBalance, timestamp, id.databaseValue]
            )
        }
    }

    func setArchived(_ id: AccountID, isArchived: Bool) async throws {
        try await setArchivedFlag(id, isArchived: isArchived, table: "account", database: database) { db in
            if isArchived {
                try checkNotLastActiveAccount(id, in: db)
            }
        }
    }

    func reorder(_ ids: [AccountID]) async throws {
        try await reorderRows(ids, table: "account", database: database)
    }

    func remove(_ id: AccountID) async throws -> RemovalOutcome {
        try await removeRow(id, table: "account", foreignKey: "account_id", database: database) { db in
            try checkNotLastActiveAccount(id, in: db)
        }
    }

    func observeAccounts(includingArchived: Bool) -> AsyncThrowingStream<[Account], any Error> {
        database.observe { db in
            let filter = includingArchived ? "" : "WHERE is_archived = 0"
            return try Row.fetchAll(db, sql: "SELECT * FROM account \(filter) ORDER BY sort_order, created_at")
                .map { try Account(row: $0) }
        }
    }
}

// MARK: Operazioni comuni a conti e categorie

/// Il conto `id` non può sparire se è l'ultimo attivo. Un conto già archiviato non conta.
private func checkNotLastActiveAccount(_ id: AccountID, in db: Database) throws {
    let isActive = try Row.fetchOne(
        db,
        sql: "SELECT 1 FROM account WHERE id = ? AND is_archived = 0",
        arguments: [id.databaseValue]
    ) != nil
    let otherActive = try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM account WHERE id != ? AND is_archived = 0",
        arguments: [id.databaseValue]
    ) ?? 0
    if isActive, otherActive == 0 {
        throw RepositoryError.lastActiveAccount
    }
}

private func validName(_ name: String) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw RepositoryError.nameEmpty }
    return trimmed
}

private func nextSortOrder(table: String, in db: Database) throws -> Int {
    try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM \(table)") ?? 0
}

/// Esegue `update`, verifica che abbia toccato la riga e aggiorna i metadati nella stessa transazione.
private func updateRow(
    database: AppDatabase,
    update: @escaping @Sendable (Database, String) throws -> Void
) async throws {
    let timestamp = Timestamp.string(database.now())
    try await database.writer.write { db in
        try update(db, timestamp)
        guard db.changesCount > 0 else { throw RepositoryError.notFound }
        try database.touchMetadata(db, timestamp: timestamp)
    }
}

private func setArchivedFlag<Entity>(
    _ id: EntityID<Entity>,
    isArchived: Bool,
    table: String,
    database: AppDatabase,
    check: @escaping @Sendable (Database) throws -> Void = { _ in }
) async throws {
    try await updateRow(database: database) { db, timestamp in
        try check(db)
        try db.execute(
            sql: "UPDATE \(table) SET is_archived = ?, updated_at = ? WHERE id = ?",
            arguments: [isArchived, timestamp, id.databaseValue]
        )
    }
}

private func reorderRows<Entity>(_ ids: [EntityID<Entity>], table: String, database: AppDatabase) async throws {
    let timestamp = Timestamp.string(database.now())
    try await database.writer.write { db in
        for (index, id) in ids.enumerated() {
            try db.execute(
                sql: "UPDATE \(table) SET sort_order = ?, updated_at = ? WHERE id = ?",
                arguments: [index, timestamp, id.databaseValue]
            )
        }
        try database.touchMetadata(db, timestamp: timestamp)
    }
}

/// Cancella la riga, o la archivia se ha operazioni collegate.
private func removeRow<Entity>(
    _ id: EntityID<Entity>,
    table: String,
    foreignKey: String,
    database: AppDatabase,
    check: @escaping @Sendable (Database) throws -> Void = { _ in }
) async throws -> RemovalOutcome {
    let timestamp = Timestamp.string(database.now())
    return try await database.writer.write { db in
        try check(db)
        let isUsed = try Row.fetchOne(
            db,
            sql: "SELECT 1 FROM operation WHERE \(foreignKey) = ? LIMIT 1",
            arguments: [id.databaseValue]
        ) != nil
        let outcome: RemovalOutcome
        if isUsed {
            try db.execute(
                sql: "UPDATE \(table) SET is_archived = 1, updated_at = ? WHERE id = ?",
                arguments: [timestamp, id.databaseValue]
            )
            outcome = .archived
        } else {
            try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [id.databaseValue])
            outcome = .deleted
        }
        guard db.changesCount > 0 else { throw RepositoryError.notFound }
        try database.touchMetadata(db, timestamp: timestamp)
        return outcome
    }
}
