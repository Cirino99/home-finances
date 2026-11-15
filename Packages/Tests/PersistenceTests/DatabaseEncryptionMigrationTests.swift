import Core
import Foundation
import Testing
@testable import Persistence

/// Migrazione dei dati di prima della cifratura (piano della cifratura, step 4).
@MainActor
final class DatabaseEncryptionMigrationTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "DatabaseEncryptionMigrationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let url: URL
    let backupsDirectory: URL
    static let key = "x'" + String(repeating: "a5", count: 32) + "'"

    init() {
        url = root.appending(path: AppDatabase.fileName)
        backupsDirectory = root.appending(path: "Backups", directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func makeStore() -> DatabaseStore {
        DatabaseStore(url: url, deviceName: "Test", temporaryDirectory: root.appending(path: "tmp"))
    }

    func database(of store: DatabaseStore) throws -> AppDatabase {
        guard case .ready(let database) = store.state else { throw DataTransferError.databaseUnavailable }
        return database
    }

    /// Database in chiaro, come prima della cifratura, con `operations` uscite da 1 euro.
    func makePlaintextDatabase(operations: Int) async throws -> AppDatabase {
        let database = try AppDatabase.open(at: url)
        try await database.seedIfNeeded(currency: "EUR")
        try await add(operations, to: database)
        return database
    }

    func add(_ count: Int, to database: AppDatabase) async throws {
        let account = try #require(try await database.accounts.observeAccounts(includingArchived: false).currentValue().first)
        let categories = try await database.categories.observeCategories(includingArchived: false).currentValue()
        let category = try #require(categories.first { $0.kind == .expense })
        for _ in 0..<count {
            try await database.operations.create(OperationDraft(
                kind: .expense,
                amount: 100,
                date: try #require(Day(string: "2026-11-01")),
                accountID: account.id,
                categoryID: category.id
            ))
        }
    }

    /// Copia "prima-import" in chiaro, come le faceva l'app prima della cifratura.
    func makePlaintextBackup(of database: AppDatabase, name: String = "prima-import-2026-11-01-120000-abcd") async throws -> URL {
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let backup = backupsDirectory.appending(path: "\(name).homefinances")
        try await database.exportCopy(to: backup)
        return backup
    }

    func operationCount(in store: DatabaseStore) async throws -> Int {
        try await database(of: store).operations.allItems().count
    }

    func leftovers() throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            + ((try? FileManager.default.contentsOfDirectory(atPath: backupsDirectory.path)) ?? [])
        return names.filter { $0.hasSuffix(".encrypting") || $0.hasSuffix(".encryption-migration") }
    }

    // MARK: Migrazione riuscita

    @Test func encryptsDatabaseAndBackupsKeepingData() async throws {
        let plain = try await makePlaintextDatabase(operations: 1)
        let backup = try await makePlaintextBackup(of: plain)
        try await add(2, to: plain)
        try plain.close()

        let store = makeStore()
        await store.open(encryptionKey: Self.key)

        #expect(store.encryptionMigrationError == nil)
        #expect(AppDatabase.fileFormat(at: url) == .encrypted)
        #expect(AppDatabase.fileFormat(at: backup) == .encrypted)
        #expect(try await operationCount(in: store) == 3)
        #expect(try leftovers().isEmpty, "Niente segnaposto né file temporanei")
        #expect(store.hasExistingData, "Il segno dei dati iniziali c'è anche per il database cifrato")

        for file in [url, backup] {
            let bytes = try Data(contentsOf: file)
            #expect(bytes.range(of: Data(DefaultData.accountName.utf8)) == nil, "\(file.lastPathComponent) ancora leggibile")
        }

        // La copia cifrata funziona: "Annulla ultimo import" torna ai dati di allora.
        #expect(try await store.undoLastImport() == 1)
        #expect(try await operationCount(in: store) == 1)
        #expect(AppDatabase.fileFormat(at: url) == .encrypted)
    }

    @Test func encryptedDatabaseReopensAfterMigration() async throws {
        try await makePlaintextDatabase(operations: 2).close()
        let store = makeStore()
        await store.open(encryptionKey: Self.key)
        store.close()

        await store.open(encryptionKey: Self.key)
        #expect(try await operationCount(in: store) == 2)

        store.close()
        await store.open(encryptionKey: nil)
        guard case .failed(let error) = store.state else {
            Issue.record("Dopo la migrazione senza chiave non si apre")
            return
        }
        #expect(error as? PersistenceError == .keyRequired)
    }

    // MARK: Prestazioni (piano della cifratura, step 7)

    /// Una decina d'anni di uso intenso: 12.000 operazioni. I limiti sono larghi apposta: il test segnala
    /// solo un peggioramento evidente. I tempi misurati finiscono nel log dei test.
    @Test func largeDatabaseMigratesOpensAndExportsInReasonableTime() async throws {
        let operations = 12_000
        let plain = try await makePlaintextDatabase(operations: 1)
        try await plain.writer.write { db in
            for index in 1..<operations {
                try db.execute(
                    sql: """
                        INSERT INTO operation
                        (id, kind, amount, currency, date, account_id, category_id, note, created_at, updated_at)
                        SELECT ?, kind, amount, currency, date, account_id, category_id, ?, created_at, updated_at
                        FROM operation LIMIT 1
                        """,
                    arguments: [UUID().uuidString, "Spesa numero \(index)"]
                )
            }
        }
        try plain.close()

        let clock = ContinuousClock()
        let store = makeStore()
        var start = clock.now
        await store.open(encryptionKey: Self.key)
        let migration = clock.now - start
        #expect(store.encryptionMigrationError == nil)
        let count = try await database(of: store).writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM operation")
        }
        #expect(count == operations)

        store.close()
        start = clock.now
        await store.open(encryptionKey: Self.key)
        let reopening = clock.now - start
        _ = try database(of: store)

        start = clock.now
        let exported = try await store.exportDatabase()
        let export = clock.now - start
        #expect(try DatabaseInspector.validate(fileAt: exported).movementCount == operations)

        print("Cifratura di \(operations) operazioni — migrazione: \(migration), riapertura: \(reopening), export: \(export)")
        #expect(migration < .seconds(30))
        #expect(reopening < .seconds(2), "Si riapre a ogni sblocco")
        #expect(export < .seconds(10))
    }

    // MARK: Interruzioni

    /// L'app si era chiusa durante l'export: il database è ancora in chiaro, accanto un file a metà.
    @Test func resumesAfterInterruptionBeforeReplacement() async throws {
        try await makePlaintextDatabase(operations: 2).close()
        FileManager.default.createFile(atPath: DatabaseEncryptionMigration.markerURL(for: url).path, contents: Data())
        FileManager.default.createFile(atPath: url.path + ".encrypting", contents: Data("a metà".utf8))

        let store = makeStore()
        await store.open(encryptionKey: Self.key)

        #expect(store.encryptionMigrationError == nil)
        #expect(AppDatabase.fileFormat(at: url) == .encrypted)
        #expect(try await operationCount(in: store) == 2)
        #expect(try leftovers().isEmpty)
    }

    /// L'app si era chiusa dopo la sostituzione: database già cifrato, copie ancora in chiaro.
    @Test func resumesAfterInterruptionAfterReplacement() async throws {
        let plain = try await makePlaintextDatabase(operations: 1)
        let backup = try await makePlaintextBackup(of: plain)
        try plain.close()
        FileManager.default.createFile(atPath: DatabaseEncryptionMigration.markerURL(for: url).path, contents: Data())
        try DatabaseEncryption.encryptInPlace(url, key: Self.key)

        let store = makeStore()
        await store.open(encryptionKey: Self.key)

        #expect(store.encryptionMigrationError == nil)
        #expect(AppDatabase.fileFormat(at: backup) == .encrypted)
        #expect(try await operationCount(in: store) == 1)
        #expect(try leftovers().isEmpty)
    }

    @Test func nothingToDoForAnEncryptedDatabase() async throws {
        let store = makeStore()
        await store.open(encryptionKey: Self.key)
        try await database(of: store).seedIfNeeded(currency: "EUR")
        store.close()
        #expect(!DatabaseEncryptionMigration.isNeeded(databaseURL: url, backups: []))
    }

    // MARK: Controllo

    @Test func verificationRejectsADifferentCopy() async throws {
        let plain = try await makePlaintextDatabase(operations: 1)
        let encrypted = root.appending(path: "copia.sqlite")
        try plain.close()
        try DatabaseEncryption.exportEncrypted(from: url, to: encrypted, key: Self.key)
        try DatabaseEncryption.verify(encrypted: encrypted, key: Self.key, matches: url)

        // L'originale cambia dopo la copia: le righe non tornano più.
        let reopened = try AppDatabase.open(at: url)
        try await add(1, to: reopened)
        try reopened.close()
        #expect(throws: DatabaseEncryptionError.verificationFailed) {
            try DatabaseEncryption.verify(encrypted: encrypted, key: Self.key, matches: url)
        }
    }

    @Test func failedEncryptionLeavesTheOriginalUntouched() async throws {
        try await makePlaintextDatabase(operations: 2).close()

        // Cartella non scrivibile, come con lo spazio esaurito: la copia cifrata non si crea.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        #expect(throws: (any Error).self) {
            try DatabaseEncryption.encryptInPlace(url, key: Self.key)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)

        // Non i byte: aprendolo, SQLite può aggiornare dati di servizio del file. Contano i dati e il formato.
        #expect(AppDatabase.fileFormat(at: url) == .plaintext)
        #expect(!FileManager.default.fileExists(atPath: url.path + ".encrypting"))
        let reopened = try AppDatabase.open(at: url)
        defer { try? reopened.close() }
        #expect(try await reopened.operations.allItems().count == 2)
    }
}
