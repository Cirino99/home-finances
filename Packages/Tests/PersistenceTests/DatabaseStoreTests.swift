import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

/// Export e import su file reali in cartelle temporanee (§ 11).
@MainActor
final class DatabaseStoreTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "DatabaseStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func databaseURL(_ name: String) -> URL {
        root.appending(path: name, directoryHint: .isDirectory).appending(path: AppDatabase.fileName)
    }

    /// Store su un proprio database, con dati iniziali e `operations` uscite da 1 euro.
    func makeStore(
        _ name: String,
        operations: Int = 0,
        opener: ((URL) throws -> AppDatabase)? = nil
    ) async throws -> DatabaseStore {
        let store = DatabaseStore(
            url: databaseURL(name),
            deviceName: "Test",
            temporaryDirectory: root.appending(path: "tmp-\(name)"),
            passwordIterations: 1000,
            opener: opener
        )
        let database = try currentDatabase(of: store)
        try await database.seedIfNeeded(currency: "EUR")
        for index in 0..<operations {
            try await add(to: database, day: index + 1)
        }
        return store
    }

    func currentDatabase(of store: DatabaseStore) throws -> AppDatabase {
        guard case .ready(let database) = store.state else {
            throw DataTransferError.databaseUnavailable
        }
        return database
    }

    func add(to database: AppDatabase, day: Int) async throws {
        let accounts = try await first(database.accounts.observeAccounts(includingArchived: false))
        let categories = try await first(database.categories.observeCategories(includingArchived: false))
        try await database.operations.create(OperationDraft(
            kind: .expense,
            amount: 100,
            date: try #require(Day(year: 2026, month: 1, day: day)),
            accountID: try #require(accounts.first?.id),
            categoryID: try #require(categories.first { $0.kind == .expense }?.id)
        ))
    }

    func first<Value: Sendable>(_ stream: AsyncThrowingStream<Value, any Error>) async throws -> Value {
        for try await value in stream {
            return value
        }
        throw CancellationError()
    }

    func count(in store: DatabaseStore) async throws -> Int {
        try await currentDatabase(of: store).operations.allItems().count
    }

    /// Scrive un file e restituisce il percorso.
    func writeFile(_ data: Data, name: String = "file.homefinances") throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: name)
        try data.write(to: url)
        return url
    }

    /// Esporta un database valido e permette di manometterlo.
    func tamperedExport(_ change: (Database) throws -> Void) async throws -> URL {
        let store = try await makeStore("source", operations: 1)
        let exported = try await store.exportDatabase()
        try tamper(fileAt: exported, change)
        return exported
    }

    /// Sincrona: in un contesto `async` si userebbe la variante che richiede una closure `@Sendable`.
    private func tamper(fileAt url: URL, _ change: (Database) throws -> Void) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try change(db)
        }
        try queue.close()
    }

    // MARK: Export

    @Test func exportProducesCompactStandaloneFile() async throws {
        let store = try await makeStore("a", operations: 2)
        let exported = try await store.exportDatabase()

        #expect(exported.pathExtension == "homefinances")
        #expect(exported.lastPathComponent.hasPrefix("Home Finances Test "))
        let folder = try FileManager.default.contentsOfDirectory(atPath: exported.deletingLastPathComponent().path)
        #expect(folder == [exported.lastPathComponent], "Nessun file di appoggio accanto alla copia")

        let summary = try DatabaseInspector.validate(fileAt: exported)
        #expect(summary.operationCount == 2)
        #expect(summary.lastModifiedBy == "Test")
    }

    @Test func removingTemporaryFileDeletesIt() async throws {
        let store = try await makeStore("a")
        let exported = try await store.exportDatabase()
        store.removeTemporaryFile(exported)
        #expect(!FileManager.default.fileExists(atPath: exported.path))
    }

    @Test func leftoverTemporaryFilesAreRemovedAtLaunch() async throws {
        let store = try await makeStore("a")
        let exported = try await store.exportDatabase()

        _ = DatabaseStore(
            url: databaseURL("a"),
            deviceName: "Test",
            temporaryDirectory: root.appending(path: "tmp-a")
        )
        #expect(!FileManager.default.fileExists(atPath: exported.path))
    }

    @Test func exportDuringWritesIsConsistent() async throws {
        let store = try await makeStore("a", operations: 3)
        let database = try currentDatabase(of: store)

        async let export = store.exportDatabase()
        for day in 4...20 {
            try await add(to: database, day: day)
        }
        let summary = try DatabaseInspector.validate(fileAt: try await export)
        #expect((3...20).contains(summary.operationCount))
    }

    @Test func csvContainsEveryOperation() async throws {
        let store = try await makeStore("a", operations: 2)
        let csv = try await store.exportCSV()
        let text = try String(contentsOf: csv, encoding: .utf8)
        #expect(csv.pathExtension == "csv")
        #expect(text.contains(CSVDocument.header))
        #expect(text.components(separatedBy: "2026-01-").count == 3)
    }

    // MARK: Import riuscito

    @Test func importReplacesDataIdentically() async throws {
        let source = try await makeStore("source", operations: 3)
        let target = try await makeStore("target", operations: 1)
        let sourceID = try currentDatabase(of: source).metadata().databaseID
        let generation = target.generation

        let exported = try await source.exportDatabase()
        let preview = try await target.prepareImport(from: exported)
        #expect(preview.incoming.operationCount == 3)
        #expect(preview.current.operationCount == 1)
        #expect(preview.isDifferentDatabase)

        #expect(try await target.performImport(preview) == 3)

        #expect(target.generation == generation + 1)
        #expect(try await count(in: target) == 3)
        #expect(try currentDatabase(of: target).metadata().databaseID == sourceID)
        #expect(!FileManager.default.fileExists(atPath: preview.fileURL.path), "Il file temporaneo va eliminato")
    }

    @Test func prepareDoesNotTouchCurrentData() async throws {
        let source = try await makeStore("source", operations: 3)
        let target = try await makeStore("target", operations: 1)

        let preview = try await target.prepareImport(from: try await source.exportDatabase())
        target.cancelImport(preview)

        #expect(try await count(in: target) == 1)
        #expect(!target.hasBackup)
        #expect(!FileManager.default.fileExists(atPath: preview.fileURL.path))
    }

    @Test func importedDatabaseIsUsable() async throws {
        let source = try await makeStore("source", operations: 1)
        let target = try await makeStore("target")
        _ = try await target.performImport(try await target.prepareImport(from: try await source.exportDatabase()))

        try await add(to: try currentDatabase(of: target), day: 15)
        #expect(try await count(in: target) == 2)
    }

    // MARK: Protezione con password

    @Test func protectedExportContainsNoReadableData() async throws {
        let store = try await makeStore("source", operations: 1)
        let exported = try await store.exportDatabase(password: "una password lunga")
        let data = try Data(contentsOf: exported)

        #expect(EncryptedDatabaseFile.isEncrypted(data))
        #expect(data.range(of: Data("SQLite format 3".utf8)) == nil)
        #expect(data.range(of: Data(DefaultData.accountName.utf8)) == nil)
        #expect(throws: DataTransferError.notADatabase) {
            _ = try DatabaseInspector.validate(fileAt: exported)
        }
        let folder = try FileManager.default.contentsOfDirectory(atPath: exported.deletingLastPathComponent().path)
        #expect(folder == [exported.lastPathComponent], "Nessuna copia in chiaro")
    }

    @Test func protectedFileImportsWithRightPassword() async throws {
        let source = try await makeStore("source", operations: 3)
        let target = try await makeStore("target", operations: 1)
        let exported = try await source.exportDatabase(password: "una password lunga")

        let preview = try await target.prepareImport(from: exported, password: "una password lunga")
        #expect(preview.incoming.operationCount == 3)
        #expect(try await target.performImport(preview) == 3)
        #expect(try await count(in: target) == 3)
    }

    @Test func protectedFileAsksForPassword() async throws {
        let source = try await makeStore("source", operations: 1)
        let target = try await makeStore("target", operations: 1)
        let exported = try await source.exportDatabase(password: "una password lunga")

        await #expect(throws: DataTransferError.passwordRequired) {
            _ = try await target.prepareImport(from: exported)
        }
        await #expect(throws: DataTransferError.wrongPassword) {
            _ = try await target.prepareImport(from: exported, password: "sbagliata")
        }
        #expect(try await count(in: target) == 1)
    }

    @Test func passwordIsIgnoredOnUnprotectedFile() async throws {
        let source = try await makeStore("source", operations: 1)
        let target = try await makeStore("target")
        let exported = try await source.exportDatabase()

        let preview = try await target.prepareImport(from: exported, password: "qualsiasi")
        #expect(preview.incoming.operationCount == 1)
    }

    /// Dopo la decifratura valgono gli stessi controlli: una password giusta non rende affidabile il file.
    @Test func protectedFileStillGoesThroughValidation() async throws {
        let file = try await tamperedExport { db in
            try db.execute(sql: "CREATE VIEW altra AS SELECT * FROM operation")
        }
        let encrypted = try EncryptedDatabaseFile.encrypt(Data(contentsOf: file), password: "password", iterations: 1000)
        let target = try await makeStore("target", operations: 1)

        await #expect(throws: DataTransferError.unexpectedContent) {
            _ = try await target.prepareImport(from: try writeFile(encrypted), password: "password")
        }
    }

    // MARK: Import rifiutato

    func expectRejected(_ file: URL, _ error: DataTransferError) async throws {
        let target = try await makeStore("target", operations: 1)
        await #expect(throws: error) {
            _ = try await target.prepareImport(from: file)
        }
        #expect(try await count(in: target) == 1, "I dati attuali non si toccano")
    }

    @Test func rejectsFileThatIsNotSQLite() async throws {
        try await expectRejected(try writeFile(Data("non sono un database".utf8)), .notADatabase)
    }

    @Test func rejectsEmptySQLiteWithoutTables() async throws {
        let url = root.appending(path: "empty.homefinances")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE altro (id INTEGER)")
        }
        try queue.close()
        try await expectRejected(url, .missingTables)
    }

    @Test func rejectsNewerSchema() async throws {
        let file = try await tamperedExport { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99')")
        }
        try await expectRejected(file, .newerSchema)
    }

    @Test func rejectsCorruptedFile() async throws {
        let store = try await makeStore("source", operations: 1)
        let exported = try await store.exportDatabase()
        var data = try Data(contentsOf: exported)
        // Si danneggia il contenuto, oltre l'intestazione di SQLite.
        for index in 200..<min(data.count, 3000) {
            data[index] = 0xFF
        }
        let file = try writeFile(data, name: "corrotto.homefinances")

        let target = try await makeStore("target", operations: 1)
        await #expect(throws: DataTransferError.self) {
            _ = try await target.prepareImport(from: file)
        }
        #expect(try await count(in: target) == 1)
    }

    /// Un trigger nel file eseguirebbe codice a ogni scrittura dell'app.
    @Test func rejectsTriggers() async throws {
        let file = try await tamperedExport { db in
            try db.execute(sql: """
                CREATE TRIGGER spia AFTER INSERT ON operation
                BEGIN DELETE FROM category; END
                """)
        }
        try await expectRejected(file, .unexpectedContent)
    }

    @Test func rejectsViews() async throws {
        let file = try await tamperedExport { db in
            try db.execute(sql: "CREATE VIEW altra AS SELECT * FROM operation")
        }
        try await expectRejected(file, .unexpectedContent)
    }

    @Test func rejectsDifferentSchema() async throws {
        let file = try await tamperedExport { db in
            try db.execute(sql: "ALTER TABLE operation ADD COLUMN extra TEXT")
        }
        try await expectRejected(file, .unexpectedContent)
    }

    @Test func rejectsUnreadableRows() async throws {
        let file = try await tamperedExport { db in
            try db.execute(sql: "UPDATE operation SET date = 'domani'")
        }
        try await expectRejected(file, .corruptedData)
    }

    @Test func rejectsMissingForeignKeyTargets() async throws {
        let file = try await tamperedExport { db in
            try db.execute(sql: "DELETE FROM account")
        }
        try await expectRejected(file, .integrityCheckFailed)
    }

    @Test func rejectsFileMissingDatabaseID() async throws {
        let file = try await tamperedExport { db in
            try db.execute(sql: "DELETE FROM app_metadata WHERE key = 'database_id'")
        }
        try await expectRejected(file, .corruptedData)
    }

    // MARK: Errori e annullamento

    @Test func failureDuringReplacementRestoresBackup() async throws {
        let source = try await makeStore("source", operations: 3)
        let opens = OpenCounter()
        let url = databaseURL("target")
        let target = try await makeStore("target", operations: 1) { fileURL in
            opens.count += 1
            // La riapertura dopo la sostituzione fallisce; quella dopo il ripristino riesce.
            if opens.count == 2 {
                throw DataTransferError.databaseUnavailable
            }
            return try AppDatabase.open(at: fileURL, deviceName: "Test")
        }
        let preview = try await target.prepareImport(from: try await source.exportDatabase())

        await #expect(throws: DataTransferError.databaseUnavailable) {
            _ = try await target.performImport(preview)
        }

        #expect(try await count(in: target) == 1, "Nessuna perdita di dati")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func undoRestoresPreviousData() async throws {
        let source = try await makeStore("source", operations: 3)
        let target = try await makeStore("target", operations: 1)
        #expect(!target.hasBackup)

        _ = try await target.performImport(try await target.prepareImport(from: try await source.exportDatabase()))
        #expect(target.hasBackup)

        let generation = target.generation
        #expect(try await target.undoLastImport() == 1)
        #expect(target.generation == generation + 1)
        #expect(try await count(in: target) == 1)
        #expect(!target.hasBackup, "La copia usata non resta disponibile")

        await #expect(throws: DataTransferError.noBackup) {
            _ = try await target.undoLastImport()
        }
    }

    @Test func keepsOnlyLastThreeBackups() async throws {
        let source = try await makeStore("source", operations: 1)
        let target = try await makeStore("target")

        for _ in 0..<5 {
            _ = try await target.performImport(try await target.prepareImport(from: try await source.exportDatabase()))
        }

        let backups = try FileManager.default.contentsOfDirectory(
            at: databaseURL("target").deletingLastPathComponent().appending(path: "Backups"),
            includingPropertiesForKeys: nil
        )
        #expect(backups.count == 3, "File trovati: \(backups.map(\.lastPathComponent))")
    }

    @Test func backupIsFoundAfterRestart() async throws {
        let source = try await makeStore("source", operations: 1)
        let target = try await makeStore("target")
        _ = try await target.performImport(try await target.prepareImport(from: try await source.exportDatabase()))

        let restarted = DatabaseStore(url: databaseURL("target"), deviceName: "Test")
        #expect(restarted.hasBackup)
    }

    // MARK: Apertura

    @Test func retriesAfterFailedOpen() async throws {
        let opens = OpenCounter()
        let store = DatabaseStore(
            url: databaseURL("retry"),
            deviceName: "Test",
            temporaryDirectory: root.appending(path: "tmp-retry"),
            opener: { url in
                opens.count += 1
                if opens.count == 1 {
                    throw DataTransferError.databaseUnavailable
                }
                return try AppDatabase.open(at: url)
            }
        )
        guard case .failed = store.state else {
            Issue.record("La prima apertura doveva fallire")
            return
        }
        #expect(store.state.hasExistingData, "Database illeggibile: si assume che i dati ci siano")

        store.retryIfNeeded()

        #expect(try currentDatabase(of: store).sqliteVersion().isEmpty == false)
        #expect(!store.state.hasExistingData)
    }
}

@MainActor
private final class OpenCounter {
    var count = 0
}
