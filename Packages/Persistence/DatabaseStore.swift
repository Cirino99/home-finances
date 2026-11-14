import Core
import Foundation
import GRDB
import Observation

/// Il database in uso: lo apre, lo esporta e lo sostituisce con uno importato (§ 10).
@MainActor
@Observable
public final class DatabaseStore: DataTransferring {
    public enum State {
        /// Non ancora aperto, o chiuso al blocco: la chiave c'è solo ad app sbloccata (§ 5.7).
        case closed
        case ready(AppDatabase)
        case failed(any Error)
    }

    public private(set) var state: State = .closed
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
    private let opener: (URL, String?) throws -> AppDatabase
    private let passwordIterations: UInt32
    /// Chiave con cui il database è aperto, o si è provato ad aprirlo; si cancella alla chiusura.
    private var encryptionKey: String?

    /// `opener` e `passwordIterations` si possono sostituire nei test: per simulare un errore
    /// durante la sostituzione, e per non calcolare ogni volta una chiave lenta.
    init(
        url: URL?,
        deviceName: String,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory.appending(path: "HomeFinancesTransfer"),
        now: @escaping () -> Date = { Date() },
        passwordIterations: UInt32 = EncryptedDatabaseFile.defaultIterations,
        opener: ((URL, String?) throws -> AppDatabase)? = nil
    ) {
        self.url = url
        self.deviceName = deviceName
        self.temporaryDirectory = temporaryDirectory
        self.now = now
        self.passwordIterations = passwordIterations
        self.opener = opener ?? { try AppDatabase.open(at: $0, deviceName: deviceName, encryptionKey: $1) }
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

    // MARK: Apertura e chiusura

    /// Apre il database dopo lo sblocco (§ 5.7). Un database nuovo nasce cifrato con `encryptionKey`.
    ///
    /// Un database in chiaro di prima della cifratura si apre ancora senza chiave, finché la migrazione
    /// non lo cifra (piano della cifratura, step 4). Uno cifrato senza chiave non si apre: `keyRequired`.
    public func open(encryptionKey: String?) {
        if case .ready = state { return }
        self.encryptionKey = encryptionKey
        state = openState()
    }

    /// Al blocco (§ 5.7): chiude le connessioni e dimentica la chiave. Riaprire richiede di nuovo lo sblocco.
    public func close() {
        if case .ready(let database) = state {
            try? database.close()
        }
        state = .closed
        encryptionKey = nil
    }

    /// Riprova se l'apertura era fallita: subito dopo un riavvio iOS può avviare l'app
    /// quando il file non è ancora accessibile. Usa la chiave dell'ultimo tentativo.
    public func retryIfNeeded() {
        if case .failed = state {
            state = openState()
        }
    }

    /// Ci sono dati da proteggere? Serve ad app bloccata, senza la chiave (§ 5.7): decide se il PIN
    /// dimenticato si può reimpostare e se si tratta di un ripristino (§ 5.2, § 5.5).
    ///
    /// - nessun file: no;
    /// - file in chiaro: lo si legge, e se non si riesce si assume di sì;
    /// - file cifrato: sì se i dati iniziali sono stati inseriti, cosa che lascia un segno accanto al file.
    ///   Senza il segno è un database creato all'onboarding e mai usato.
    public var hasExistingData: Bool {
        guard let url else { return true }
        switch AppDatabase.fileFormat(at: url) {
        case .missing: return false
        case .plaintext: return AppDatabase.plaintextFileIsSeeded(at: url)
        case .encrypted: return FileManager.default.fileExists(atPath: seededMarkerURL(for: url).path)
        }
    }

    /// Da chiamare dopo l'inserimento dei dati iniziali: lascia il segno letto da `hasExistingData`.
    public func markSeeded() {
        guard let url else { return }
        FileManager.default.createFile(atPath: seededMarkerURL(for: url).path, contents: Data())
    }

    private func seededMarkerURL(for url: URL) -> URL {
        URL(filePath: url.path + ".seeded")
    }

    private func openState() -> State {
        guard let url else { return .failed(DataTransferError.databaseUnavailable) }
        let key: String?
        switch AppDatabase.fileFormat(at: url) {
        case .plaintext:
            key = nil
        case .encrypted:
            guard let encryptionKey else { return .failed(PersistenceError.keyRequired) }
            key = encryptionKey
        case .missing:
            key = encryptionKey
        }
        do {
            return .ready(try opener(url, key))
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
        let movements = try await database.movements.allMovements()
        let destination = try newTemporaryFolder().appending(path: exportFileName(extension: "csv", device: ""))
        try CSVDocument.data(forMovements: movements).write(to: destination, options: .atomic)
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
        let reopened = try opener(url, openingKey(for: url))
        state = .ready(reopened)
        if (try? reopened.isSeeded()) == true {
            markSeeded()
        }
        generation += 1
        return try await reopened.summary().movementCount
    }

    /// La chiave per il file messo al posto del database: nessuna se è in chiaro.
    private func openingKey(for url: URL) -> String? {
        AppDatabase.fileFormat(at: url) == .plaintext ? nil : encryptionKey
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
            state = .ready(try opener(url, openingKey(for: url)))
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
