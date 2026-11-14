import Foundation
import GRDB
import Testing

/// Prova di integrazione di SQLCipher (piano della cifratura, step 1): GRDB deve usare SQLCipher
/// e non il SQLite di sistema, e un database cifrato deve aprirsi solo con la sua chiave.
struct SQLCipherTests {
    let folder = FileManager.default.temporaryDirectory
        .appending(path: "SQLCipherTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// Chiave grezza da 256 bit nel formato di SQLCipher, `x'…'`: niente derivazione da password (piano, § 3.2).
    static func rawKey(_ byte: UInt8) -> String {
        "x'" + String(repeating: String(format: "%02x", byte), count: 32) + "'"
    }

    func configuration(key: String?) -> Configuration {
        var configuration = Configuration()
        if let key {
            configuration.prepareDatabase { db in
                try db.usePassphrase(key)
            }
        }
        return configuration
    }

    func databaseURL() throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "cifrato.sqlite")
    }

    /// Crea un database cifrato con una riga dal testo riconoscibile.
    func makeEncryptedDatabase(key: String) throws -> URL {
        let url = try databaseURL()
        let queue = try DatabaseQueue(path: url.path, configuration: configuration(key: key))
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE note (testo TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO note (testo) VALUES ('nota segreta molto riconoscibile')")
        }
        try queue.close()
        return url
    }

    @Test func grdbUsesSQLCipher() throws {
        let queue = try DatabaseQueue()
        let version = try queue.read { db in
            try String.fetchOne(db, sql: "PRAGMA cipher_version")
        }
        // Con il SQLite di sistema il pragma non esiste e non restituisce nulla.
        let cipherVersion = try #require(version, "GRDB non è collegato a SQLCipher")
        #expect(cipherVersion.hasPrefix("4."), "Attesa SQLCipher 4, trovata \(cipherVersion)")
    }

    @Test func encryptedDatabaseReopensWithItsKey() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = Self.rawKey(0xA5)
        let url = try makeEncryptedDatabase(key: key)

        let queue = try DatabaseQueue(path: url.path, configuration: configuration(key: key))
        defer { try? queue.close() }
        let text = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT testo FROM note")
        }
        #expect(text == "nota segreta molto riconoscibile")
    }

    @Test func wrongKeyOrNoKeyCannotRead() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try makeEncryptedDatabase(key: Self.rawKey(0xA5))

        for key in [Self.rawKey(0x5A), nil] {
            #expect(throws: DatabaseError.self) {
                let queue = try DatabaseQueue(path: url.path, configuration: configuration(key: key))
                defer { try? queue.close() }
                _ = try queue.read { db in
                    try String.fetchOne(db, sql: "SELECT testo FROM note")
                }
            }
        }
    }

    /// Il contenuto non si legge nei byte del file: né il testo delle righe né l'intestazione di SQLite.
    @Test func fileContainsNoPlaintext() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try makeEncryptedDatabase(key: Self.rawKey(0xA5))
        let bytes = try Data(contentsOf: url)

        #expect(!bytes.isEmpty)
        #expect(bytes.range(of: Data("nota segreta".utf8)) == nil)
        #expect(bytes.range(of: Data("CREATE TABLE".utf8)) == nil)
        #expect(!bytes.starts(with: Data("SQLite format 3".utf8)), "L'intestazione in chiaro indica un file non cifrato")
    }

    /// Un database in chiaro si apre ancora senza chiave: servirà per la migrazione e per i file importati.
    @Test func plaintextDatabaseStillOpensWithoutKey() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try databaseURL()
        let plain = try DatabaseQueue(path: url.path)
        try plain.write { db in
            try db.execute(sql: "CREATE TABLE note (testo TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO note (testo) VALUES ('in chiaro')")
        }
        try plain.close()

        #expect(try Data(contentsOf: url).starts(with: Data("SQLite format 3".utf8)))
        let reopened = try DatabaseQueue(path: url.path)
        defer { try? reopened.close() }
        #expect(try reopened.read { try String.fetchOne($0, sql: "SELECT testo FROM note") } == "in chiaro")
    }
}
