import Core
import Foundation
import Testing
@testable import Persistence

/// Apertura del database cifrato dopo lo sblocco e chiusura al blocco (piano della cifratura, step 3).
@MainActor
final class DatabaseStoreEncryptionTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "DatabaseStoreEncryptionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let url: URL
    static let key = "x'" + String(repeating: "a5", count: 32) + "'"
    static let otherKey = "x'" + String(repeating: "5a", count: 32) + "'"

    init() {
        url = root.appending(path: AppDatabase.fileName)
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

    func failure(of store: DatabaseStore) -> (any Error)? {
        guard case .failed(let error) = store.state else { return nil }
        return error
    }

    @Test func newDatabaseIsEncryptedAndReopensWithTheKey() async throws {
        let store = makeStore()
        await store.open(encryptionKey: Self.key)
        try await database(of: store).seedIfNeeded(currency: "EUR")
        store.close()

        guard case .closed = store.state else {
            Issue.record("Al blocco lo store si chiude")
            return
        }
        #expect(AppDatabase.fileFormat(at: url) == .encrypted)
        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data(DefaultData.accountName.utf8)) == nil, "Nessun dato leggibile nel file")

        await store.open(encryptionKey: Self.key)
        #expect(try database(of: store).isSeeded())
    }

    @Test func closingForgetsTheKey() async throws {
        let store = makeStore()
        await store.open(encryptionKey: Self.key)
        store.close()

        await store.open(encryptionKey: nil)
        #expect(failure(of: store) as? PersistenceError == .keyRequired)
    }

    @Test func wrongKeyDoesNotOpen() async throws {
        let store = makeStore()
        await store.open(encryptionKey: Self.key)
        try await database(of: store).seedIfNeeded(currency: "EUR")
        store.close()

        await store.open(encryptionKey: Self.otherKey)
        let error = try #require(failure(of: store))
        #expect(error as? PersistenceError == .keyMismatch, "Una chiave c'era: è sbagliata")
    }

    // MARK: Cancellazione (§ 5.7)

    /// Dati di un altro dispositivo: si cancellano e il database rinasce con la chiave di questo.
    @Test func erasingUnreadableDataStartsANewDatabase() async throws {
        let store = makeStore()
        await store.open(encryptionKey: Self.key)
        try await database(of: store).seedIfNeeded(currency: "EUR")
        store.markSeeded()
        store.close()
        await store.open(encryptionKey: Self.otherKey)
        #expect(failure(of: store) as? PersistenceError == .keyMismatch)

        let generation = store.generation
        try store.eraseAllData()
        #expect(!store.hasExistingData)
        #expect(store.generation == generation + 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0 != "tmp" }.isEmpty, "Nessun file rimasto")

        await store.open(encryptionKey: Self.otherKey)
        #expect(try !database(of: store).isSeeded(), "Vuoto, come al primo avvio")
        #expect(AppDatabase.fileFormat(at: url) == .encrypted)
    }

    @Test func erasingRemovesBackupsAndMarkers() async throws {
        let store = makeStore()
        await store.open(encryptionKey: Self.key)
        try await database(of: store).seedIfNeeded(currency: "EUR")
        store.markSeeded()
        let backups = root.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try await database(of: store).exportCopy(to: backups.appending(path: "prima-import-1.homefinances"), encryptionKey: Self.key)
        FileManager.default.createFile(atPath: DatabaseEncryptionMigration.markerURL(for: url).path, contents: Data())

        // Da bloccata, come per il PIN dimenticato.
        store.close()
        try store.eraseAllData()

        #expect(!store.hasBackup)
        #expect(!store.hasExistingData)
        #expect(!FileManager.default.fileExists(atPath: backups.path))
        #expect(!FileManager.default.fileExists(atPath: DatabaseEncryptionMigration.markerURL(for: url).path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func erasingAnOpenDatabaseClosesIt() async throws {
        let store = makeStore()
        await store.open(encryptionKey: Self.key)
        try store.eraseAllData()
        guard case .closed = store.state else {
            Issue.record("Dopo la cancellazione lo store è chiuso")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Senza chiave (Face ID con il vecchio token) un database di prima della cifratura si apre in chiaro:
    /// la migrazione aspetta il PIN.
    @Test func plaintextDatabaseOpensWithoutKeyAndStaysPlaintext() async throws {
        let plain = try AppDatabase.open(at: url)
        try await plain.seedIfNeeded(currency: "EUR")
        try plain.close()

        let store = makeStore()
        await store.open(encryptionKey: nil)
        #expect(try database(of: store).isSeeded())
        store.close()
        #expect(AppDatabase.fileFormat(at: url) == .plaintext)
    }

    @Test func fileFormatIsReadWithoutOpening() throws {
        #expect(AppDatabase.fileFormat(at: url) == .missing)

        let plain = try AppDatabase.open(at: url)
        try plain.close()
        #expect(AppDatabase.fileFormat(at: url) == .plaintext)

        try FileManager.default.removeItem(at: url)
        let encrypted = try AppDatabase.open(at: url, encryptionKey: Self.key)
        try encrypted.close()
        #expect(AppDatabase.fileFormat(at: url) == .encrypted)
    }

    // MARK: Dati presenti, da bloccati

    @Test func encryptedDatabaseHasDataOnlyAfterSeeding() async throws {
        let store = makeStore()
        #expect(!store.hasExistingData, "Nessun file")

        await store.open(encryptionKey: Self.key)
        store.close()
        #expect(!store.hasExistingData, "Creato all'onboarding ma mai usato")

        await store.open(encryptionKey: Self.key)
        try await database(of: store).seedIfNeeded(currency: "EUR")
        store.markSeeded()
        store.close()
        #expect(store.hasExistingData)
        #expect(makeStore().hasExistingData, "Anche dopo un riavvio, senza la chiave")
    }

    @Test func plaintextDatabaseIsReadToKnowIfItHasData() async throws {
        let plain = try AppDatabase.open(at: url)
        try plain.close()
        #expect(!makeStore().hasExistingData)

        let seeded = try AppDatabase.open(at: url)
        try await seeded.seedIfNeeded(currency: "EUR")
        try seeded.close()
        #expect(makeStore().hasExistingData)
    }
}
