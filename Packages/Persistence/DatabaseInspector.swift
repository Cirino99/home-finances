import Core
import Foundation
import GRDB

/// Controlli su un file da importare (§ 10.4). Il file arriva da fuori e non è affidabile:
/// lo si apre in sola lettura e si accetta solo ciò che l'app stessa avrebbe potuto creare.
enum DatabaseInspector {
    private static let requiredTables = ["account", "category", "operation", "app_metadata", "grdb_migrations"]

    /// Riassunto del file, se è accettabile. Altrimenti lancia un `DataTransferError`.
    static func validate(fileAt url: URL) throws -> DatabaseSummary {
        var configuration = Configuration()
        configuration.readonly = true
        do {
            let queue = try DatabaseQueue(path: url.path, configuration: configuration)
            defer { try? queue.close() }
            return try queue.read { db in
                try checkIntegrity(db)
                try checkStructure(db)
                try checkRows(db)
                return try summary(db)
            }
        } catch let error as DataTransferError {
            throw error
        } catch is DatabaseError {
            throw DataTransferError.notADatabase
        } catch {
            throw DataTransferError.corruptedData
        }
    }

    static func summary(_ db: Database) throws -> DatabaseSummary {
        let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM app_metadata")
        var values: [String: String] = [:]
        for row in rows {
            values[row["key"]] = row["value"] as String
        }
        guard let databaseID = values[MetadataKey.databaseID] else {
            throw DataTransferError.corruptedData
        }
        // Movimenti = operazioni + trasferimenti (§ 10.4). Un file creato prima della `v2` non ha la tabella.
        let movements = try db.tableExists("transfer")
            ? "SELECT date FROM operation UNION ALL SELECT date FROM transfer"
            : "SELECT date FROM operation"
        let row = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS count, MAX(date) AS latest FROM (\(movements))")
        let latest: String? = row?["latest"]
        return DatabaseSummary(
            databaseID: databaseID,
            lastModifiedAt: try values[MetadataKey.lastModifiedAt].map(Timestamp.date),
            lastModifiedBy: values[MetadataKey.lastModifiedBy],
            movementCount: row?["count"] ?? 0,
            latestMovementDate: latest.flatMap(Day.init(string:))
        )
    }

    private static func checkIntegrity(_ db: Database) throws {
        guard try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok" else {
            throw DataTransferError.integrityCheckFailed
        }
        guard try Row.fetchOne(db, sql: "PRAGMA foreign_key_check") == nil else {
            throw DataTransferError.integrityCheckFailed
        }
    }

    private static func checkStructure(_ db: Database) throws {
        for table in requiredTables {
            guard try db.tableExists(table) else { throw DataTransferError.missingTables }
        }

        // Trigger e viste eseguirebbero codice del file a ogni scrittura o lettura.
        let hasExecutableObjects = try Row.fetchOne(
            db,
            sql: "SELECT 1 FROM sqlite_master WHERE type IN ('trigger', 'view') LIMIT 1"
        ) != nil
        if hasExecutableObjects {
            throw DataTransferError.unexpectedContent
        }

        let applied = Set(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
        let known = AppDatabase.migrator.migrations
        guard applied.isSubset(of: Set(known)) else {
            throw DataTransferError.newerSchema
        }
        // Le migrazioni si applicano in ordine: un file dell'app ne ha sempre una sequenza iniziale.
        guard let last = known.prefix(applied.count).last, applied == Set(known.prefix(applied.count)) else {
            throw DataTransferError.unexpectedContent
        }

        // Lo schema dev'essere identico a quello che l'app crea con le stesse migrazioni: un file `v1`
        // con una tabella `transfer` già presente farebbe fallire la `v2` dopo l'import.
        if try schema(db) != referenceSchema(upTo: last) {
            throw DataTransferError.unexpectedContent
        }
    }

    /// Ogni riga dev'essere leggibile dall'app: meglio rifiutare il file ora che perdere i dati attuali.
    private static func checkRows(_ db: Database) throws {
        for row in try Row.fetchAll(db, sql: "SELECT * FROM account") {
            _ = try Account(row: row)
        }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM category") {
            _ = try OperationCategory(row: row)
        }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM operation") {
            _ = try FinanceOperation(row: row)
        }
        guard try db.tableExists("transfer") else { return }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM transfer") {
            let transfer = try AccountTransfer(row: row)
            // Il vincolo c'è nello schema, ma un file manomesso può averlo aggirato.
            guard transfer.fromAccountID != transfer.toAccountID, transfer.amount > 0 else {
                throw DataTransferError.corruptedData
            }
        }
    }

    private static func schema(_ db: Database) throws -> Set<[String]> {
        let sql = """
            SELECT type, name, sql FROM sqlite_master
            WHERE name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations' AND sql IS NOT NULL
            """
        return Set(try Row.fetchAll(db, sql: sql).map { row in
            [row["type"] as String, row["name"] as String, row["sql"] as String]
        })
    }

    /// Schema di un database nuovo, creato dall'app con le migrazioni fino a `migration` compresa.
    private static func referenceSchema(upTo migration: String) throws -> Set<[String]> {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: migration)
        return try queue.read { db in
            try schema(db)
        }
    }
}
