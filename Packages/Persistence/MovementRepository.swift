import Core
import Foundation
import GRDB

/// Letture che uniscono operazioni e trasferimenti (§ 6.3): elenco dei movimenti e saldi dei conti.
struct GRDBMovementRepository: MovementRepository {
    let database: AppDatabase

    func observeMovements(_ query: MovementQuery) -> AsyncThrowingStream<[MovementListItem], any Error> {
        database.observe { db in
            try Self.fetchMovements(query, in: db)
        }
    }

    /// Saldo iniziale + entrate − uscite + trasferimenti ricevuti − inviati (§ 6.4), per tutti i conti.
    func observeBalances() -> AsyncThrowingStream<[AccountBalance], any Error> {
        database.observe { db in
            let sql = """
                SELECT a.*,
                    COALESCE((SELECT SUM(amount) FROM operation WHERE account_id = a.id AND kind = 'income'), 0) AS income,
                    COALESCE((SELECT SUM(amount) FROM operation WHERE account_id = a.id AND kind = 'expense'), 0) AS expense,
                    COALESCE((SELECT SUM(amount) FROM transfer WHERE to_account_id = a.id), 0) AS received,
                    COALESCE((SELECT SUM(amount) FROM transfer WHERE from_account_id = a.id), 0) AS sent
                FROM account a
                ORDER BY a.sort_order, a.created_at
                """
            return try Row.fetchAll(db, sql: sql).map(AccountBalance.init(row:))
        }
    }

    // MARK: Elenco

    /// Stesse colonne, con gli stessi nomi, nelle due parti della `UNION ALL`.
    /// `movement_type` dice quale forma leggere (`MovementListItem(row:)`).
    private static let operationSelect = """
        SELECT 'operation' AS movement_type,
               o.id AS id, o.kind AS kind, o.amount AS amount, o.currency AS currency, o.date AS date,
               o.account_id AS account_id, o.category_id AS category_id,
               NULL AS from_account_id, NULL AS to_account_id,
               o.note AS note, o.created_at AS created_at, o.updated_at AS updated_at,
               c.id AS c_id, c.name AS c_name, c.kind AS c_kind, c.symbol AS c_symbol, c.color AS c_color,
               c.is_archived AS c_is_archived, c.sort_order AS c_sort_order,
               c.created_at AS c_created_at, c.updated_at AS c_updated_at,
               a.name AS account_name, NULL AS from_account_name, NULL AS to_account_name
        FROM operation o
        JOIN category c ON c.id = o.category_id
        JOIN account a ON a.id = o.account_id
        """

    private static let transferSelect = """
        SELECT 'transfer' AS movement_type,
               t.id AS id, NULL AS kind, t.amount AS amount, t.currency AS currency, t.date AS date,
               NULL AS account_id, NULL AS category_id,
               t.from_account_id AS from_account_id, t.to_account_id AS to_account_id,
               t.note AS note, t.created_at AS created_at, t.updated_at AS updated_at,
               NULL AS c_id, NULL AS c_name, NULL AS c_kind, NULL AS c_symbol, NULL AS c_color,
               NULL AS c_is_archived, NULL AS c_sort_order,
               NULL AS c_created_at, NULL AS c_updated_at,
               NULL AS account_name, fa.name AS from_account_name, ta.name AS to_account_name
        FROM transfer t
        JOIN account fa ON fa.id = t.from_account_id
        JOIN account ta ON ta.id = t.to_account_id
        """

    static func fetchMovements(_ query: MovementQuery, in db: Database) throws -> [MovementListItem] {
        var parts: [String] = []
        var arguments = StatementArguments()
        let searchPattern = query.searchText
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : "%\(GRDBOperationRepository.escapingLikeWildcards($0))%" }

        if query.includesOperations {
            var conditions: [String] = []
            if let month = query.month {
                conditions.append("o.date BETWEEN ? AND ?")
                arguments += [month.firstDay.string, month.lastDay.string]
            }
            if let kind = query.kind?.operationKind {
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
            if let searchPattern {
                // Anche il nome del conto, come per i trasferimenti: il campo invita a cercare per conto.
                conditions.append(#"(o.note LIKE ? ESCAPE '\' OR c.name LIKE ? ESCAPE '\' OR a.name LIKE ? ESCAPE '\')"#)
                arguments += [searchPattern, searchPattern, searchPattern]
            }
            parts.append(select(operationSelect, where: conditions))
        }

        if query.includesTransfers {
            var conditions: [String] = []
            if let month = query.month {
                conditions.append("t.date BETWEEN ? AND ?")
                arguments += [month.firstDay.string, month.lastDay.string]
            }
            if let accountID = query.accountID {
                conditions.append("(t.from_account_id = ? OR t.to_account_id = ?)")
                arguments += [accountID.databaseValue, accountID.databaseValue]
            }
            if let searchPattern {
                conditions.append(#"(t.note LIKE ? ESCAPE '\' OR fa.name LIKE ? ESCAPE '\' OR ta.name LIKE ? ESCAPE '\')"#)
                arguments += [searchPattern, searchPattern, searchPattern]
            }
            parts.append(select(transferSelect, where: conditions))
        }

        guard !parts.isEmpty else { return [] }

        // L'id rende stabile la paginazione tra righe con la stessa data e lo stesso istante di creazione.
        let sql = """
            SELECT * FROM (\(parts.joined(separator: " UNION ALL ")))
            ORDER BY date DESC, created_at DESC, id DESC
            LIMIT ? OFFSET ?
            """
        arguments += [query.limit, query.offset]
        return try Row.fetchAll(db, sql: sql, arguments: arguments).map(MovementListItem.init(row:))
    }

    private static func select(_ base: String, where conditions: [String]) -> String {
        conditions.isEmpty ? base : base + " WHERE " + conditions.joined(separator: " AND ")
    }
}
