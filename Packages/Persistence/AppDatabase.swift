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

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Apre (o crea) il database su file, in modalità WAL tramite `DatabasePool`.
    public static func open(at url: URL, configuration: Configuration = Configuration()) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        return try AppDatabase(writer: pool)
    }

    /// Database in memoria, per test e anteprime.
    public static func inMemory(configuration: Configuration = Configuration()) throws -> AppDatabase {
        try AppDatabase(writer: DatabaseQueue(configuration: configuration))
    }

    /// `Application Support/<bundle-id>/homefinances.sqlite`.
    public static func defaultURL(bundleIdentifier: String) throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: fileName, directoryHint: .notDirectory)
    }

    /// Le migrazioni dello schema; la `v1` arriva nello Sprint 2 (§ 6.2).
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        return migrator
    }

    /// Versione di SQLite in uso, per la diagnostica.
    public func sqliteVersion() throws -> String {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "?"
        }
    }
}
