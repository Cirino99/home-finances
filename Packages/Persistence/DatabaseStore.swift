import Core
import Foundation
import GRDB
import Observation

/// Il database in uso: lo apre, lo esporta e lo sostituisce con uno importato (§ 10).
@MainActor
@Observable
public final class DatabaseStore: DataTransferring {
    public enum State {
        case ready(AppDatabase)
        case failed(any Error)

        /// Database con dati ma senza PIN significa ripristino da backup (§ 5.5). Se il database non si può
        /// leggere si assume che i dati ci siano: è il caso più prudente, chiede il codice del dispositivo
        /// e non permette di reimpostare il PIN.
        public var hasExistingData: Bool {
            switch self {
            case .ready(let database): (try? database.isSeeded()) ?? true
            case .failed: true
            }
        }
    }

    public private(set) var state: State
    /// Cambia a ogni sostituzione del database: l'interfaccia si ricostruisce da zero.
    public private(set) var generation = 0
    public private(set) var hasBackup = false
    /// Se i dati finiscono nei backup di sistema: iCloud, Finder, Time Machine (§ 5.5).
    public private(set) var isIncludedInSystemBackup = true

    private static let maxBackups = 3

    private let url: URL?
    private let deviceName: String
    private let temporaryDirectory: URL
    private let now: () -> Date
    private let opener: (URL) throws -> AppDatabase
    private let passwordIterations: UInt32

    /// `opener` e `passwordIterations` si possono sostituire nei test: per simulare un errore
    /// durante la sostituzione, e per non calcolare ogni volta una chiave lenta.
    init(
        url: URL?,
        deviceName: String,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory.appending(path: "HomeFinancesTransfer"),
        now: @escaping () -> Date = { Date() },
        passwordIterations: UInt32 = EncryptedDatabaseFile.defaultIterations,
        opener: ((URL) throws -> AppDatabase)? = nil
    ) {
        self.url = url
        self.deviceName = deviceName
        self.temporaryDirectory = temporaryDirectory
        self.now = now
        self.passwordIterations = passwordIterations
        let opener = opener ?? { try AppDatabase.open(at: $0, deviceName: deviceName) }
        self.opener = opener
        state = Self.open(url: url, opener: opener)
        // I file di dati non cifrati non devono sopravvivere a una chiusura inattesa dell'app.
        try? FileManager.default.removeItem(at: temporaryDirectory)
        hasBackup = !existingBackups().isEmpty
        if let excluded = try? databaseDirectory?.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup {
            isIncludedInSystemBackup = !excluded
        }
    }

    /// La cartella e non il file: così vale anche per i file di appoggio di SQLite e per le copie
    /// di sicurezza, e resta valida quando un import sostituisce il database.
    public func setIncludedInSystemBackup(_ isIncluded: Bool) throws {
        guard var directory = databaseDirectory else { throw DataTransferError.databaseUnavailable }
        var values = URLResourceValues()
        values.isExcludedFromBackup = !isIncluded
        try directory.setResourceValues(values)
        isIncludedInSystemBackup = isIncluded
    }

    private var databaseDirectory: URL? {
        url?.deletingLastPathComponent()
    }

    /// `Application Support/<bundle-id>/homefinances.sqlite`.
    public convenience init(bundleIdentifier: String, deviceName: String) {
        self.init(url: try? AppDatabase.defaultURL(bundleIdentifier: bundleIdentifier), deviceName: deviceName)
    }

    /// Riprova se l'apertura era fallita: subito dopo un riavvio iOS può avviare l'app
    /// quando il file non è ancora accessibile.
    public func retryIfNeeded() {
        if case .failed = state {
            state = Self.open(url: url, opener: opener)
        }
    }

    private static func open(url: URL?, opener: (URL) throws -> AppDatabase) -> State {
        guard let url else { return .failed(DataTransferError.databaseUnavailable) }
        do {
            return .ready(try opener(url))
        } catch {
            return .failed(error)
        }
    }

    private func currentDatabase() throws -> AppDatabase {
        guard case .ready(let database) = state else { throw DataTransferError.databaseUnavailable }
        return database
    }

    // MARK: Export

    public func exportDatabase(password: String? = nil) async throws -> URL {
        let database = try currentDatabase()
        let destination = try newTemporaryFolder().appending(path: exportFileName(extension: "homefinances", device: deviceName))
        try await database.exportCopy(to: destination)
        if let password {
            do {
                try await Self.encryptFile(at: destination, password: password, iterations: passwordIterations)
            } catch {
                // Mai lasciare in giro la copia in chiaro.
                removeTemporaryFile(destination)
                throw error
            }
        }
        return destination
    }

    /// Sostituisce il file con la versione cifrata, senza passare da un file in chiaro con un altro nome.
    @concurrent
    private nonisolated static func encryptFile(at url: URL, password: String, iterations: UInt32) async throws {
        let encrypted = try EncryptedDatabaseFile.encrypt(Data(contentsOf: url), password: password, iterations: iterations)
        try encrypted.write(to: url, options: .atomic)
    }

    /// Lascia il file com'è se non è cifrato; altrimenti lo sostituisce con la versione decifrata.
    @concurrent
    private nonisolated static func decryptFileIfNeeded(at url: URL, password: String?) async throws {
        let data = try Data(contentsOf: url)
        guard EncryptedDatabaseFile.isEncrypted(data) else { return }
        guard let password else { throw DataTransferError.passwordRequired }
        try EncryptedDatabaseFile.decrypt(data, password: password).write(to: url, options: .atomic)
    }

    public func exportCSV() async throws -> URL {
        let database = try currentDatabase()
        let items = try await database.operations.allItems()
        let destination = try newTemporaryFolder().appending(path: exportFileName(extension: "csv", device: ""))
        try CSVDocument.data(for: items).write(to: destination, options: .atomic)
        return destination
    }

    public func removeTemporaryFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// `Home Finances iPhone 2026-10-30 2145.homefinances` (§ 10.2).
    private func exportFileName(extension fileExtension: String, device: String) -> String {
        let cleanDevice = device.replacingOccurrences(of: "[/:\\\\]", with: " ", options: .regularExpression)
        let parts = ["Home Finances", cleanDevice, timestamp(spaced: true)].filter { !$0.isEmpty }
        return parts.joined(separator: " ") + "." + fileExtension
    }

    private func timestamp(spaced: Bool) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now())
        let date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        if spaced {
            return date + String(format: " %02d%02d", parts.hour ?? 0, parts.minute ?? 0)
        }
        return date + String(format: "-%02d%02d%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    private func newTemporaryFolder() throws -> URL {
        let folder = temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: Import

    public func prepareImport(from source: URL, password: String? = nil) async throws -> ImportPreview {
        let database = try currentDatabase()
        let candidate = try newTemporaryFolder().appending(path: "import.homefinances")

        let isScoped = source.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                source.stopAccessingSecurityScopedResource()
            }
        }
        do {
            try FileManager.default.copyItem(at: source, to: candidate)
            try await Self.decryptFileIfNeeded(at: candidate, password: password)
            let incoming = try await Self.validate(fileAt: candidate)
            return ImportPreview(fileURL: candidate, current: try await database.summary(), incoming: incoming)
        } catch {
            removeTemporaryFile(candidate)
            throw error
        }
    }

    public func cancelImport(_ preview: ImportPreview) {
        removeTemporaryFile(preview.fileURL)
    }

    public func performImport(_ preview: ImportPreview) async throws -> Int {
        let database = try currentDatabase()
        defer { removeTemporaryFile(preview.fileURL) }

        // Si ricontrolla: il file temporaneo potrebbe essere cambiato dopo l'anteprima.
        _ = try await Self.validate(fileAt: preview.fileURL)
        let backup = try await makeBackup(of: database)

        do {
            return try await replaceDatabase(closing: database, with: preview.fileURL)
        } catch {
            restoreAfterFailure(from: backup)
            throw error
        }
    }

    public func undoLastImport() async throws -> Int {
        let database = try currentDatabase()
        guard let backup = existingBackups().last else { throw DataTransferError.noBackup }
        let count = try await replaceDatabase(closing: database, with: backup)
        // Usata: il prossimo annullamento risalirà alla copia precedente.
        try? FileManager.default.removeItem(at: backup)
        hasBackup = !existingBackups().isEmpty
        return count
    }

    /// Lontano dal main actor: su un file grande i controlli richiedono tempo.
    @concurrent
    private nonisolated static func validate(fileAt url: URL) async throws -> DatabaseSummary {
        try DatabaseInspector.validate(fileAt: url)
    }

    private func replaceDatabase(closing database: AppDatabase, with file: URL) async throws -> Int {
        guard let url else { throw DataTransferError.databaseUnavailable }
        try database.close()
        try swapDatabaseFile(at: url, with: file)
        let reopened = try opener(url)
        state = .ready(reopened)
        generation += 1
        return try await reopened.summary().operationCount
    }

    /// La copia si fa nella stessa cartella del database: solo così la sostituzione è atomica.
    private func swapDatabaseFile(at url: URL, with file: URL) throws {
        let fileManager = FileManager.default
        let incoming = url.deletingLastPathComponent().appending(path: "incoming-\(UUID().uuidString).sqlite")
        try fileManager.copyItem(at: file, to: incoming)
        do {
            for suffix in ["-wal", "-shm"] {
                try? fileManager.removeItem(at: URL(filePath: url.path + suffix))
            }
            _ = try fileManager.replaceItemAt(url, withItemAt: incoming)
        } catch {
            try? fileManager.removeItem(at: incoming)
            throw error
        }
    }

    /// Qualcosa è andato storto dopo la chiusura del database: si torna alla copia di sicurezza (§ 10.4).
    private func restoreAfterFailure(from backup: URL) {
        guard let url else { return }
        do {
            try swapDatabaseFile(at: url, with: backup)
            state = .ready(try opener(url))
        } catch {
            state = .failed(error)
        }
        generation += 1
    }

    // MARK: Copie di sicurezza

    private var backupsDirectory: URL? {
        url?.deletingLastPathComponent().appending(path: "Backups", directoryHint: .isDirectory)
    }

    /// Dalla più vecchia alla più recente: il nome contiene data e ora.
    private func existingBackups() -> [URL] {
        guard let backupsDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { $0.pathExtension == "homefinances" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func makeBackup(of database: AppDatabase) async throws -> URL {
        guard let backupsDirectory else { throw DataTransferError.databaseUnavailable }
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let name = "prima-import-\(timestamp(spaced: false))-\(UUID().uuidString.prefix(4)).homefinances"
        let backup = backupsDirectory.appending(path: name)
        try await database.exportCopy(to: backup)
        for old in existingBackups().dropLast(Self.maxBackups) {
            try? FileManager.default.removeItem(at: old)
        }
        // Eventuali file di appoggio lasciati da versioni precedenti.
        let files = (try? FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension != "homefinances" {
            try? FileManager.default.removeItem(at: file)
        }
        hasBackup = true
        return backup
    }
}

extension AppDatabase {
    /// Copia consistente, sicura anche con l'app in uso, compatta e senza WAL separato (§ 10.3).
    @concurrent
    func exportCopy(to destination: URL) async throws {
        let queue = try DatabaseQueue(path: destination.path)
        do {
            try writer.backup(to: queue)
            try await queue.writeWithoutTransaction { db in
                // La copia eredita il WAL dall'originale: tutti i dati devono finire nel file principale.
                guard try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE") == "delete" else {
                    throw DataTransferError.databaseUnavailable
                }
                try db.execute(sql: "VACUUM")
            }
            try queue.close()
            Self.removeSidecarFiles(of: destination)
        } catch {
            try? queue.close()
            Self.removeSidecarFiles(of: destination)
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    @concurrent
    func summary() async throws -> DatabaseSummary {
        try await writer.read { db in
            try DatabaseInspector.summary(db)
        }
    }

    func close() throws {
        try writer.close()
    }

    /// File di appoggio di SQLite accanto a una copia già chiusa: non contengono più nulla di utile.
    private nonisolated static func removeSidecarFiles(of file: URL) {
        for suffix in ["-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: URL(filePath: file.path + suffix))
        }
    }
}
