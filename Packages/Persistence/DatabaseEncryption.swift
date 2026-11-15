import Foundation
import GRDB

public enum DatabaseEncryptionError: Error, Equatable {
    /// Il file cifrato non è identico all'originale: niente sostituzione.
    case verificationFailed
}

/// Copie da file in chiaro a file cifrati con SQLCipher (§ 5.7). Le usano la migrazione dei dati
/// esistenti e l'import. La copia in chiaro per l'export è `AppDatabase.exportCopy(to:encryptionKey:)`.
enum DatabaseEncryption {
    /// Scrive in `destination` una copia cifrata con `key` del database in chiaro `plaintext`,
    /// con `sqlcipher_export`. `destination` non deve esistere.
    static func exportEncrypted(from plaintext: URL, to destination: URL, key: String) throws {
        let queue = try DatabaseQueue(path: plaintext.path)
        defer { try? queue.close() }
        try queue.inDatabase { db in
            // Prima tutto nel file principale: con il WAL, l'export leggerebbe comunque i dati giusti,
            // ma il file in chiaro che resta dopo deve essere completo per il confronto.
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            try db.execute(sql: "ATTACH DATABASE ? AS encrypted KEY ?", arguments: [destination.path, key])
            defer { try? db.execute(sql: "DETACH DATABASE encrypted") }
            try db.execute(sql: "SELECT sqlcipher_export('encrypted')")
        }
    }

    /// Controlla che il file cifrato sia integro e contenga le stesse tabelle con le stesse righe dell'originale.
    static func verify(encrypted: URL, key: String, matches plaintext: URL) throws {
        let expected = try rowCounts(at: plaintext, key: nil)
        let actual = try rowCounts(at: encrypted, key: key)
        guard !expected.isEmpty, actual == expected else { throw DatabaseEncryptionError.verificationFailed }
    }

    /// Righe di ogni tabella, dopo un `integrity_check` riuscito.
    private static func rowCounts(at url: URL, key: String?) throws -> [String: Int] {
        var configuration = Configuration()
        configuration.readonly = true
        if let key {
            configuration.prepareDatabase { db in
                try db.usePassphrase(key)
            }
        }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db in
            guard try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok" else {
                throw DatabaseEncryptionError.verificationFailed
            }
            let tables = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
            )
            var counts: [String: Int] = [:]
            for table in tables {
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table.quotedDatabaseIdentifier)") ?? 0
            }
            return counts
        }
    }

    /// Copia cifrata e controllata di `plaintext`. Se il controllo non riesce, la copia non resta.
    static func encryptedCopy(of plaintext: URL, to destination: URL, key: String) throws {
        do {
            try exportEncrypted(from: plaintext, to: destination, key: key)
            try verify(encrypted: destination, key: key, matches: plaintext)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Sostituisce il file `url`, in chiaro, con la sua versione cifrata: esporta accanto, controlla,
    /// sostituisce in modo atomico. Se qualcosa va storto l'originale resta com'è.
    static func encryptInPlace(_ url: URL, key: String) throws {
        let fileManager = FileManager.default
        let temporary = URL(filePath: url.path + ".encrypting")
        try? fileManager.removeItem(at: temporary)
        do {
            try encryptedCopy(of: url, to: temporary, key: key)
            // I file di appoggio appartengono al file in chiaro: dopo il checkpoint non contengono più nulla.
            for suffix in ["-wal", "-shm"] {
                try? fileManager.removeItem(at: URL(filePath: url.path + suffix))
            }
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}

/// Migrazione dei dati di prima della cifratura (§ 5.7, piano della cifratura § 3.8).
///
/// Ogni passo può ripartire: la decisione si basa sul formato reale dei file, non su cosa si credeva fatto.
/// Il segnaposto dice solo che una migrazione è cominciata, e sparisce quando è finita.
enum DatabaseEncryptionMigration {
    static func markerURL(for databaseURL: URL) -> URL {
        URL(filePath: databaseURL.path + ".encryption-migration")
    }

    /// `true` se c'è qualcosa da cifrare: il database o una copia di sicurezza in chiaro, o una migrazione interrotta.
    static func isNeeded(databaseURL: URL, backups: [URL]) -> Bool {
        AppDatabase.fileFormat(at: databaseURL) == .plaintext
            || backups.contains { AppDatabase.fileFormat(at: $0) == .plaintext }
            || FileManager.default.fileExists(atPath: markerURL(for: databaseURL).path)
    }

    static func run(databaseURL: URL, backups: [URL], key: String) throws {
        let fileManager = FileManager.default
        let marker = markerURL(for: databaseURL)
        fileManager.createFile(atPath: marker.path, contents: Data())

        // 1. Il database: si cifra solo se è ancora in chiaro. Se l'app si era chiusa dopo la sostituzione,
        //    è già cifrato e si passa oltre.
        if AppDatabase.fileFormat(at: databaseURL) == .plaintext {
            try DatabaseEncryption.encryptInPlace(databaseURL, key: key)
        }

        // 2. Le copie "prima-import": stesse regole, una alla volta.
        for backup in backups where AppDatabase.fileFormat(at: backup) == .plaintext {
            try DatabaseEncryption.encryptInPlace(backup, key: key)
        }

        // 3. Fine: niente più da riprendere.
        try fileManager.removeItem(at: marker)
    }
}
