import Core
import Foundation
import GRDB

/// Punto unico di apertura del database (§ 5.6).
///
/// Nessun altro modulo crea connessioni o conosce il percorso del file:
/// quando arriverà SQLCipher, basterà cambiare questo tipo.
public final class AppDatabase: Sendable {
    /// Nome del file nella cartella dell'app (§ 5.5).
    public static let fileName = "homefinances.sqlite"

    let writer: any DatabaseWriter
    let now: @Sendable () -> Date
    /// Nome del dispositivo, per `last_modified_by`.
    let deviceName: String

    private init(writer: any DatabaseWriter, deviceName: String, now: @escaping @Sendable () -> Date) throws {
        self.writer = writer
        self.deviceName = deviceName
        self.now = now
        try Self.migrator.migrate(writer)
    }

    /// Apre (o crea) il database su file, in modalità WAL tramite `DatabasePool`.
    public static func open(
        at url: URL,
        configuration: Configuration = Configuration(),
        deviceName: String = "",
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        return try AppDatabase(writer: pool, deviceName: deviceName, now: now)
    }

    /// Database in memoria, per test e anteprime.
    public static func inMemory(
        configuration: Configuration = Configuration(),
        deviceName: String = "",
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> AppDatabase {
        try AppDatabase(writer: DatabaseQueue(configuration: configuration), deviceName: deviceName, now: now)
    }

    /// `Application Support/<bundle-id>/homefinances.sqlite`.
    public static func defaultURL(bundleIdentifier: String) throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: fileName, directoryHint: .notDirectory)
    }

    /// Versione di SQLite in uso, per la diagnostica.
    public func sqliteVersion() throws -> String {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "?"
        }
    }

    // MARK: Repository

    public var operations: any OperationRepository {
        GRDBOperationRepository(database: self)
    }

    public var categories: any CategoryRepository {
        GRDBCategoryRepository(database: self)
    }

    public var accounts: any AccountRepository {
        GRDBAccountRepository(database: self)
    }

    public var transfers: any TransferRepository {
        GRDBTransferRepository(database: self)
    }

    public var movements: any MovementRepository {
        GRDBMovementRepository(database: self)
    }

    // MARK: Dati iniziali

    /// `true` se il database contiene già dati: distingue un'installazione nuova
    /// da un ripristino da backup senza PIN (§ 5.5).
    public func isSeeded() throws -> Bool {
        try writer.read { db in
            try Self.hasSeedData(db)
        }
    }

    /// Un dato apposito e non i conti, che l'utente può cambiare. Controlla anche i conti
    /// per i database creati prima che esistesse questa chiave.
    private static func hasSeedData(_ db: Database) throws -> Bool {
        let hasKey = try Row.fetchOne(
            db,
            sql: "SELECT 1 FROM app_metadata WHERE key = ?",
            arguments: [MetadataKey.seededAt]
        ) != nil
        return try hasKey || Row.fetchOne(db, sql: "SELECT 1 FROM account LIMIT 1") != nil
    }

    /// Inserisce il conto e le categorie di default (§ 6.2). Non fa nulla se ci sono già.
    public func seedIfNeeded(currency: String) async throws {
        guard currency.count == 3, currency.allSatisfy({ $0.isASCII && $0.isUppercase }) else {
            throw PersistenceError.invalidCurrency(currency)
        }
        let timestamp = Timestamp.string(now())
        try await writer.write { [self] db in
            guard try !Self.hasSeedData(db) else { return }

            try db.execute(
                sql: "INSERT INTO app_metadata (key, value) VALUES (?, ?)",
                arguments: [MetadataKey.seededAt, timestamp]
            )
            try db.execute(
                sql: """
                    INSERT INTO account (id, name, currency, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, DefaultData.accountName, currency, timestamp, timestamp]
            )
            for (index, category) in DefaultData.categories.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO category (id, name, kind, symbol, color, sort_order, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        UUID().uuidString, category.name, category.kind.rawValue, category.symbol,
                        category.color.rawValue, index, timestamp, timestamp,
                    ]
                )
            }
            try touchMetadata(db, timestamp: timestamp)
        }
    }

    // MARK: Metadati

    public struct Metadata: Equatable, Sendable {
        public let databaseID: String
        public let lastModifiedAt: Date?
        public let lastModifiedBy: String?
    }

    public func metadata() throws -> Metadata {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM app_metadata")
            var values: [String: String] = [:]
            for row in rows {
                values[row["key"]] = row["value"] as String
            }
            guard let databaseID = values[MetadataKey.databaseID] else {
                throw PersistenceError.corruptedValue(column: MetadataKey.databaseID)
            }
            return Metadata(
                databaseID: databaseID,
                lastModifiedAt: try values[MetadataKey.lastModifiedAt].map(Timestamp.date),
                lastModifiedBy: values[MetadataKey.lastModifiedBy]
            )
        }
    }

    /// Da chiamare nella stessa transazione di ogni scrittura su account, category, operation e transfer (§ 6.2).
    func touchMetadata(_ db: Database, timestamp: String) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO app_metadata (key, value) VALUES (?, ?), (?, ?)",
            arguments: [MetadataKey.lastModifiedAt, timestamp, MetadataKey.lastModifiedBy, deviceName]
        )
    }

    // MARK: Letture reattive

    /// Emette subito il valore attuale e poi ogni cambiamento delle tabelle lette da `fetch` (§ 6.3).
    func observe<Value: Equatable & Sendable>(
        _ fetch: @escaping @Sendable (Database) throws -> Value
    ) -> AsyncThrowingStream<Value, any Error> {
        AsyncThrowingStream { continuation in
            let cancellable = ValueObservation
                .tracking(fetch)
                .removeDuplicates()
                .start(
                    in: writer,
                    scheduling: .async(onQueue: DispatchQueue(label: "HomeFinances.observation")),
                    onError: { continuation.finish(throwing: $0) },
                    onChange: { continuation.yield($0) }
                )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    // MARK: Migrazioni

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        // Schema v1 (§ 6.2). Una migrazione rilasciata non si modifica mai: se ne aggiunge una nuova.
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE account (
                    id               TEXT PRIMARY KEY NOT NULL,
                    name             TEXT NOT NULL,
                    currency         TEXT NOT NULL,
                    initial_balance  INTEGER NOT NULL DEFAULT 0,
                    is_archived      INTEGER NOT NULL DEFAULT 0,
                    sort_order       INTEGER NOT NULL DEFAULT 0,
                    created_at       TEXT NOT NULL,
                    updated_at       TEXT NOT NULL
                );

                CREATE TABLE category (
                    id           TEXT PRIMARY KEY NOT NULL,
                    name         TEXT NOT NULL,
                    kind         TEXT NOT NULL CHECK (kind IN ('income','expense')),
                    symbol       TEXT NOT NULL,
                    color        TEXT NOT NULL,
                    is_archived  INTEGER NOT NULL DEFAULT 0,
                    sort_order   INTEGER NOT NULL DEFAULT 0,
                    created_at   TEXT NOT NULL,
                    updated_at   TEXT NOT NULL
                );

                CREATE TABLE operation (
                    id           TEXT PRIMARY KEY NOT NULL,
                    kind         TEXT NOT NULL CHECK (kind IN ('income','expense')),
                    amount       INTEGER NOT NULL CHECK (amount > 0),
                    currency     TEXT NOT NULL,
                    date         TEXT NOT NULL,
                    account_id   TEXT NOT NULL REFERENCES account(id) ON DELETE RESTRICT,
                    category_id  TEXT NOT NULL REFERENCES category(id) ON DELETE RESTRICT,
                    note         TEXT,
                    created_at   TEXT NOT NULL,
                    updated_at   TEXT NOT NULL
                );

                CREATE INDEX idx_operation_date     ON operation(date DESC, created_at DESC);
                CREATE INDEX idx_operation_category ON operation(category_id);
                CREATE INDEX idx_operation_account  ON operation(account_id);

                CREATE TABLE app_metadata (
                    key    TEXT PRIMARY KEY NOT NULL,
                    value  TEXT NOT NULL
                );
                """)
            try db.execute(
                sql: "INSERT INTO app_metadata (key, value) VALUES (?, ?)",
                arguments: [MetadataKey.databaseID, UUID().uuidString]
            )
        }

        // Trasferimenti tra conti (§ 6.2). Non sono entrate né uscite: tabella propria.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                CREATE TABLE transfer (
                    id               TEXT PRIMARY KEY NOT NULL,
                    amount           INTEGER NOT NULL CHECK (amount > 0),
                    currency         TEXT NOT NULL,
                    date             TEXT NOT NULL,
                    from_account_id  TEXT NOT NULL REFERENCES account(id) ON DELETE RESTRICT,
                    to_account_id    TEXT NOT NULL REFERENCES account(id) ON DELETE RESTRICT,
                    note             TEXT,
                    created_at       TEXT NOT NULL,
                    updated_at       TEXT NOT NULL,
                    CHECK (from_account_id <> to_account_id)
                );

                CREATE INDEX idx_transfer_date ON transfer(date DESC, created_at DESC);
                CREATE INDEX idx_transfer_from ON transfer(from_account_id);
                CREATE INDEX idx_transfer_to   ON transfer(to_account_id);
                """)
        }
        return migrator
    }
}

public enum PersistenceError: Error, Equatable {
    case invalidCurrency(String)
    case corruptedValue(column: String)
}

enum MetadataKey {
    static let databaseID = "database_id"
    static let lastModifiedAt = "last_modified_at"
    static let lastModifiedBy = "last_modified_by"
    static let seededAt = "seeded_at"
}

/// Timestamp tecnici: ISO 8601 in UTC (§ 6.1).
enum Timestamp {
    private static let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func string(_ date: Date) -> String {
        style.format(date)
    }

    static func date(_ string: String) throws -> Date {
        try style.parse(string)
    }
}
