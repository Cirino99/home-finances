import Core
import Foundation
import GRDB

struct GRDBOperationRepository: OperationRepository {
    let database: AppDatabase

    // MARK: Scritture

    func create(_ draft: OperationDraft) async throws -> FinanceOperation {
        try draft.validate()
        let id = OperationID()
        let timestamp = database.now()
        return try await database.writer.write { [database] db in
            let currency = try checkReferences(of: draft, in: db)
            let operation = FinanceOperation(
                id: id,
                kind: draft.kind,
                amount: draft.amount,
                currency: currency,
                date: draft.date,
                accountID: draft.accountID,
                categoryID: draft.categoryID,
                note: draft.normalizedNote,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            try db.execute(
                sql: """
                    INSERT INTO operation
                    (id, kind, amount, currency, date, account_id, category_id, note, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    id.databaseValue, draft.kind.rawValue, draft.amount, currency, draft.date.string,
                    draft.accountID.databaseValue, draft.categoryID.databaseValue, draft.normalizedNote,
                    Timestamp.string(timestamp), Timestamp.string(timestamp),
                ]
            )
            try database.touchMetadata(db, timestamp: Timestamp.string(timestamp))
            return operation
        }
    }

    func update(_ id: OperationID, with draft: OperationDraft) async throws -> FinanceOperation {
        try draft.validate()
        let timestamp = database.now()
        return try await database.writer.write { [database] db in
            guard let existing = try fetchOperation(id, in: db) else { throw RepositoryError.notFound }
            let currency = try checkReferences(of: draft, in: db)
            try db.execute(
                sql: """
                    UPDATE operation
                    SET kind = ?, amount = ?, currency = ?, date = ?, account_id = ?, category_id = ?, note = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    draft.kind.rawValue, draft.amount, currency, draft.date.string,
                    draft.accountID.databaseValue, draft.categoryID.databaseValue, draft.normalizedNote,
                    Timestamp.string(timestamp), id.databaseValue,
                ]
            )
            try database.touchMetadata(db, timestamp: Timestamp.string(timestamp))
            return FinanceOperation(
                id: id,
                kind: draft.kind,
                amount: draft.amount,
                currency: currency,
                date: draft.date,
                accountID: draft.accountID,
                categoryID: draft.categoryID,
                note: draft.normalizedNote,
                createdAt: existing.createdAt,
                updatedAt: timestamp
            )
        }
    }

    func delete(_ id: OperationID) async throws {
        let timestamp = Timestamp.string(database.now())
        try await database.writer.write { [database] db in
            try db.execute(sql: "DELETE FROM operation WHERE id = ?", arguments: [id.databaseValue])
            guard db.changesCount > 0 else { throw RepositoryError.notFound }
            try database.touchMetadata(db, timestamp: timestamp)
        }
    }

    func operation(_ id: OperationID) async throws -> FinanceOperation? {
        try await database.writer.read { db in
            try fetchOperation(id, in: db)
        }
    }

    // MARK: Letture reattive

    func observeItem(_ id: OperationID) -> AsyncThrowingStream<OperationListItem?, any Error> {
        database.observe { db in
            try Row.fetchOne(db, sql: "\(Self.itemSelect) WHERE o.id = ?", arguments: [id.databaseValue])
                .map(OperationListItem.init(row:))
        }
    }

    func observeItems(_ query: OperationQuery) -> AsyncThrowingStream<[OperationListItem], any Error> {
        database.observe { db in
            try fetchItems(query, in: db)
        }
    }

    func observeRecent(limit: Int) -> AsyncThrowingStream<[OperationListItem], any Error> {
        observeItems(OperationQuery(limit: limit))
    }

    func observeTotals(for month: YearMonth) -> AsyncThrowingStream<PeriodTotals, any Error> {
        database.observe { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT \(Self.totalsColumns) FROM operation WHERE date BETWEEN ? AND ?",
                arguments: [month.firstDay.string, month.lastDay.string]
            )
            return row?.periodTotals() ?? PeriodTotals()
        }
    }

    func observeMonthlyTotals(year: Int?) -> AsyncThrowingStream<[MonthTotals], any Error> {
        database.observe { db in
            var sql = "SELECT substr(date, 1, 7) AS period, \(Self.totalsColumns) FROM operation"
            var arguments = StatementArguments()
            if let year {
                sql += " WHERE date BETWEEN ? AND ?"
                arguments += [String(format: "%04d-01-01", year), String(format: "%04d-12-31", year)]
            }
            sql += " GROUP BY period ORDER BY period DESC"
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                let period: String = row["period"]
                guard let month = YearMonth(string: period) else {
                    throw PersistenceError.corruptedValue(column: "date")
                }
                return MonthTotals(month: month, totals: row.periodTotals())
            }
        }
    }

    func observeYearlyTotals() -> AsyncThrowingStream<[YearTotals], any Error> {
        database.observe { db in
            let sql = """
                SELECT substr(date, 1, 4) AS period, \(Self.totalsColumns)
                FROM operation GROUP BY period ORDER BY period DESC
                """
            return try Row.fetchAll(db, sql: sql).map { row in
                let period: String = row["period"]
                guard let year = Int(period) else {
                    throw PersistenceError.corruptedValue(column: "date")
                }
                return YearTotals(year: year, totals: row.periodTotals())
            }
        }
    }

    // MARK: Supporto

    private static let totalsColumns = """
        COALESCE(SUM(CASE WHEN kind = 'income' THEN amount END), 0) AS income, \
        COALESCE(SUM(CASE WHEN kind = 'expense' THEN amount END), 0) AS expense
        """

    private static let itemSelect = """
        SELECT o.*,
               c.id AS c_id, c.name AS c_name, c.kind AS c_kind, c.symbol AS c_symbol, c.color AS c_color,
               c.is_archived AS c_is_archived, c.sort_order AS c_sort_order,
               c.created_at AS c_created_at, c.updated_at AS c_updated_at,
               a.name AS account_name
        FROM operation o
        JOIN category c ON c.id = o.category_id
        JOIN account a ON a.id = o.account_id
        """

    /// Verifica conto e categoria, compresa la coerenza del tipo (§ 6.2). Restituisce la valuta del conto.
    private func checkReferences(of draft: OperationDraft, in db: Database) throws -> String {
        guard let currency = try String.fetchOne(
            db, sql: "SELECT currency FROM account WHERE id = ?", arguments: [draft.accountID.databaseValue]
        ), let categoryKind = try String.fetchOne(
            db, sql: "SELECT kind FROM category WHERE id = ?", arguments: [draft.categoryID.databaseValue]
        ) else {
            throw RepositoryError.notFound
        }
        guard categoryKind == draft.kind.rawValue else { throw RepositoryError.kindMismatch }
        return currency
    }

    private func fetchOperation(_ id: OperationID, in db: Database) throws -> FinanceOperation? {
        try Row.fetchOne(db, sql: "SELECT * FROM operation WHERE id = ?", arguments: [id.databaseValue])
            .map(FinanceOperation.init(row:))
    }

    private func fetchItems(_ query: OperationQuery, in db: Database) throws -> [OperationListItem] {
        var conditions: [String] = []
        var arguments = StatementArguments()

        if let month = query.month {
            conditions.append("o.date BETWEEN ? AND ?")
            arguments += [month.firstDay.string, month.lastDay.string]
        }
        if let kind = query.kind {
            conditions.append("o.kind = ?")
            arguments += [kind.rawValue]
        }
        if let categoryID = query.categoryID {
            conditions.append("o.category_id = ?")
            arguments += [categoryID.databaseValue]
        }
        if let accountID = query.accountID {
            conditions.append("o.account_id = ?")
            arguments += [accountID.databaseValue]
        }
        if let text = query.searchText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let pattern = "%\(Self.escapingLikeWildcards(text))%"
            conditions.append(#"(o.note LIKE ? ESCAPE '\' OR c.name LIKE ? ESCAPE '\')"#)
            arguments += [pattern, pattern]
        }

        var sql = Self.itemSelect
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        // L'id rende stabile la paginazione tra righe con la stessa data e lo stesso istante di creazione.
        sql += " ORDER BY o.date DESC, o.created_at DESC, o.id DESC LIMIT ? OFFSET ?"
        arguments += [query.limit, query.offset]

        return try Row.fetchAll(db, sql: sql, arguments: arguments).map(OperationListItem.init(row:))
    }

    /// `%` e `_` del testo cercato valgono come caratteri normali, non come jolly di `LIKE`.
    static func escapingLikeWildcards(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: "%", with: #"\%"#)
            .replacingOccurrences(of: "_", with: #"\_"#)
    }
}
