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
    private var isOpening = false
    /// Cresce a ogni chiusura: un'apertura in corso che la vede cambiare non apre più nulla.
    private var closeCount = 0
    /// Sblocco arrivato mentre un'apertura era in corso: va eseguito quando quella finisce.
    private var hasPendingOpen = false
    /// Ultimo errore della migrazione alla cifratura: il database resta in chiaro e si riprova al prossimo
    /// sblocco con la chiave (§ 5.7). `nil` se è riuscita o non serviva.
    public private(set) var encryptionMigrationError: (any Error)?

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
        removeLeftoverStagedFiles()
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
    /// Con la chiave, prima di aprire cifra i dati di prima della cifratura: database e copie di sicurezza.
    /// Senza chiave (Face ID con il vecchio token) un database in chiaro si apre ancora in chiaro, e la
    /// migrazione aspetta il PIN. Un database cifrato senza chiave non si apre: `keyRequired`.
    public func open(encryptionKey: String?) async {
        if case .ready = state { return }
        self.encryptionKey = encryptionKey
        guard !isOpening else {
            hasPendingOpen = true
            return
        }
        await reopen()
    }

    /// Al blocco (§ 5.7): chiude le connessioni e dimentica la chiave. Riaprire richiede di nuovo lo sblocco.
    public func close() {
        if case .ready(let database) = state {
            try? database.close()
        }
        state = .closed
        encryptionKey = nil
        closeCount += 1
    }

    /// Riprova se l'apertura era fallita: subito dopo un riavvio iOS può avviare l'app
    /// quando il file non è ancora accessibile. Usa la chiave dell'ultimo tentativo.
    public func retryIfNeeded() async {
        guard case .failed = state, !isOpening else { return }
        await reopen()
    }

    private func reopen() async {
        isOpening = true
        let closes = closeCount
        await migrateIfNeeded()
        isOpening = false
        if closeCount == closes {
            hasPendingOpen = false
            state = openState()
        } else if hasPendingOpen {
            // Bloccata e risbloccata durante la migrazione: si riparte con la chiave del nuovo sblocco.
            hasPendingOpen = false
            await reopen()
        }
        // Altrimenti è stata bloccata: la chiave è già stata dimenticata, non si apre nulla.
    }

    /// Cifra i dati di prima della cifratura, se c'è la chiave. Se non riesce, per esempio per lo spazio,
    /// tutto resta com'era: il database si apre in chiaro e si riprova al prossimo sblocco.
    private func migrateIfNeeded() async {
        guard let url, let encryptionKey else { return }
        let backups = existingBackups()
        guard DatabaseEncryptionMigration.isNeeded(databaseURL: url, backups: backups) else { return }
        do {
            try await Self.migrate(databaseURL: url, backups: backups, key: encryptionKey)
            encryptionMigrationError = nil
        } catch {
            encryptionMigrationError = error
        }
    }

    /// Lontano dal main actor: la copia di un database grande richiede tempo.
    @concurrent
    private nonisolated static func migrate(databaseURL: URL, backups: [URL], key: String) async throws {
        try DatabaseEncryptionMigration.run(databaseURL: databaseURL, backups: backups, key: key)
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
        let format = AppDatabase.fileFormat(at: url)
        switch format {
        case .plaintext:
            key = nil
        case .encrypted:
            guard let encryptionKey else { return .failed(PersistenceError.keyRequired) }
            key = encryptionKey
        case .missing:
            key = encryptionKey
        }
        do {
            let database = try opener(url, key)
            // Dopo una migrazione, o per un database cifrato di cui si era perso il segno.
            if key != nil, (try? database.isSeeded()) == true {
                markSeeded()
            }
            return .ready(database)
        } catch let error as DatabaseError where format == .encrypted && error.resultCode == .SQLITE_NOTADB {
            // SQLCipher non riconosce le pagine: la chiave non è quella giusta.
            return .failed(PersistenceError.keyMismatch)
        } catch {
            return .failed(error)
        }
    }

    // MARK: Cancellazione

    /// Cancella il database, le copie di sicurezza e i file accanto (§ 5.7): per il PIN dimenticato e per
    /// i dati cifrati con una chiave che questo dispositivo non ha. Lo store resta chiuso: una nuova
    /// apertura crea un database vuoto. Non si annulla.
    public func eraseAllData() throws {
        guard let url, !isOpening else { throw DataTransferError.databaseUnavailable }
        if case .ready(let database) = state {
            try database.close()
        }
        state = .closed
        let fileManager = FileManager.default
        // Il database per primo: senza, anche il segno dei dati iniziali non conta più.
        let files = ["", "-wal", "-shm", "-journal", ".encrypting"].map { URL(filePath: url.path + $0) }
            + [seededMarkerURL(for: url), DatabaseEncryptionMigration.markerURL(for: url)]
            + [backupsDirectory].compactMap(\.self)
        for file in files where fileManager.fileExists(atPath: file.path) {
            try fileManager.removeItem(at: file)
        }
        removeLeftoverStagedFiles()
        hasBackup = false
        encryptionMigrationError = nil
        generation += 1
    }

    /// L'utente ha visto l'errore della migrazione: si riproverà comunque al prossimo sblocco.
    public func dismissEncryptionMigrationError() {
        encryptionMigrationError = nil
    }

    private func currentDatabase() throws -> AppDatabase {
        guard case .ready(let database) = state else { throw DataTransferError.databaseUnavailable }
        return database
    }

    // MARK: Export

    public func exportDatabase(password: String? = nil) async throws -> URL {
        let database = try currentDatabase()
        let destination = try newTemporaryFolder().appending(path: exportFileName(extension: "homefinances", device: deviceName))
        // In chiaro anche dal database cifrato (§ 10.2): il file deve aprirsi su un altro dispositivo, con
        // un'altra chiave. A proteggerlo, se l'utente la sceglie, è la password.
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
        // Cifrato prima di toccare il database in uso: se non riesce, non è cambiato nulla.
        let staged = try await stage(preview.fileURL)
        defer { try? FileManager.default.removeItem(at: staged) }
        let backup = try await makeBackup(of: database)

        do {
            return try await replaceDatabase(closing: database, with: staged)
        } catch {
            restoreAfterFailure(from: backup)
            throw error
        }
    }

    public func undoLastImport() async throws -> Int {
        let database = try currentDatabase()
        guard let backup = existingBackups().last else { throw DataTransferError.noBackup }
        let staged = try await stage(backup)
        defer { try? FileManager.default.removeItem(at: staged) }
        let count = try await replaceDatabase(closing: database, with: staged)
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

    /// `staged` viene da `stage(_:)`: è già nella cartella del database, nel formato giusto.
    private func replaceDatabase(closing database: AppDatabase, with staged: URL) async throws -> Int {
        guard let url else { throw DataTransferError.databaseUnavailable }
        try database.close()
        try swapDatabaseFile(at: url, with: staged)
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

    /// Copia di `file` pronta a prendere il posto del database, nella sua stessa cartella: solo così
    /// la sostituzione è atomica. Con la chiave, un file in chiaro (un import) diventa cifrato e viene
    /// controllato prima di usarlo (§ 5.7): sul disco dell'app i dati restano solo cifrati.
    private func stage(_ file: URL) async throws -> URL {
        let staged = try stagingURL()
        if let encryptionKey, AppDatabase.fileFormat(at: file) == .plaintext {
            try await Self.encryptedCopy(of: file, to: staged, key: encryptionKey)
        } else {
            try FileManager.default.copyItem(at: file, to: staged)
        }
        return staged
    }

    /// Copie preparate da un import o da un annullamento interrotti a metà: non servono più.
    private func removeLeftoverStagedFiles() {
        guard let databaseDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: databaseDirectory, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.lastPathComponent.hasPrefix(Self.stagingPrefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static let stagingPrefix = "incoming-"

    private func stagingURL() throws -> URL {
        guard let databaseDirectory else { throw DataTransferError.databaseUnavailable }
        return databaseDirectory.appending(path: "\(Self.stagingPrefix)\(UUID().uuidString).sqlite")
    }

    /// Lontano dal main actor: su un file grande copia e controllo richiedono tempo.
    @concurrent
    private nonisolated static func encryptedCopy(of file: URL, to destination: URL, key: String) async throws {
        try DatabaseEncryption.encryptedCopy(of: file, to: destination, key: key)
    }

    /// Mette `staged` al posto del database, chiuso. Se non riesce, `staged` si cancella.
    private func swapDatabaseFile(at url: URL, with staged: URL) throws {
        let fileManager = FileManager.default
        do {
            for suffix in ["-wal", "-shm"] {
                try? fileManager.removeItem(at: URL(filePath: url.path + suffix))
            }
            _ = try fileManager.replaceItemAt(url, withItemAt: staged)
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
    }

    /// Qualcosa è andato storto dopo la chiusura del database: si torna alla copia di sicurezza (§ 10.4).
    /// La copia è già nel formato del database, cifrata se lo era: basta copiarla.
    private func restoreAfterFailure(from backup: URL) {
        guard let url else { return }
        do {
            let staged = try stagingURL()
            try FileManager.default.copyItem(at: backup, to: staged)
            try swapDatabaseFile(at: url, with: staged)
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
        // Cifrata come il database (§ 5.7). Senza chiave (database ancora in chiaro) resta in chiaro,
        // e la cifra la migrazione al prossimo sblocco con il PIN.
        try await database.exportCopy(to: backup, encryptionKey: encryptionKey)
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
    /// Copia consistente in un file nuovo, sicura anche con l'app in uso, compatta e senza WAL separato (§ 10.3).
    ///
    /// Con `encryptionKey` la copia è cifrata con quella chiave, senza è in chiaro, qualunque sia il database
    /// di partenza (§ 5.7): `sqlcipher_export` riscrive tutto con la cifratura della destinazione. L'API di
    /// backup di SQLite, usata prima della cifratura, non copia tra file con cifrature diverse.
    @concurrent
    func exportCopy(to destination: URL, encryptionKey: String? = nil) async throws {
        do {
            // Sulla connessione di scrittura: nessuna scrittura può inserirsi a metà copia.
            try await writer.writeWithoutTransaction { db in
                // Con la chiave vuota il file collegato è in chiaro.
                try db.execute(
                    sql: "ATTACH DATABASE ? AS destination KEY ?",
                    arguments: [destination.path, encryptionKey ?? ""]
                )
                defer { try? db.execute(sql: "DETACH DATABASE destination") }
                // Un file a sé, senza il WAL dell'originale: tutti i dati nel file principale.
                guard try String.fetchOne(db, sql: "PRAGMA destination.journal_mode = DELETE") == "delete" else {
                    throw DataTransferError.databaseUnavailable
                }
                try db.execute(sql: "SELECT sqlcipher_export('destination')")
            }
            Self.removeSidecarFiles(of: destination)
        } catch {
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
