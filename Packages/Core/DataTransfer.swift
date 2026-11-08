import Foundation

/// Motivi per cui un file non si può esportare o importare (§ 10.4).
public enum DataTransferError: Error, Equatable, LocalizedError {
    case notADatabase
    case integrityCheckFailed
    case missingTables
    /// Contiene oggetti che l'app non ha creato, come trigger o tabelle diverse: non è un file affidabile.
    case unexpectedContent
    case corruptedData
    case newerSchema
    case databaseUnavailable
    case noBackup
    /// Il file è protetto: serve la password.
    case passwordRequired
    case wrongPassword

    public var errorDescription: String? {
        switch self {
        case .passwordRequired: String(localized: "Questo file è protetto da password.")
        case .wrongPassword: String(localized: "Password errata, oppure il file è stato modificato.")
        case .notADatabase: String(localized: "Questo file non è un database di Home Finances.")
        case .integrityCheckFailed: String(localized: "Il file è danneggiato.")
        case .missingTables: String(localized: "Il file non contiene i dati di Home Finances.")
        case .unexpectedContent: String(localized: "Il file contiene elementi non previsti e non può essere importato.")
        case .corruptedData: String(localized: "Il file contiene dati non validi.")
        case .newerSchema: String(localized: "Questo file è stato creato da una versione più recente dell'app. Aggiorna l'app e riprova.")
        case .databaseUnavailable: String(localized: "Il database non è disponibile.")
        case .noBackup: String(localized: "Non c'è nessuna copia di sicurezza da ripristinare.")
        }
    }
}

/// Ciò che serve per confrontare due database prima di un import (§ 10.4).
public struct DatabaseSummary: Equatable, Sendable {
    public let databaseID: String
    public let lastModifiedAt: Date?
    public let lastModifiedBy: String?
    public let movementCount: Int
    public let latestMovementDate: Day?

    public init(
        databaseID: String,
        lastModifiedAt: Date?,
        lastModifiedBy: String?,
        movementCount: Int,
        latestMovementDate: Day?
    ) {
        self.databaseID = databaseID
        self.lastModifiedAt = lastModifiedAt
        self.lastModifiedBy = lastModifiedBy
        self.movementCount = movementCount
        self.latestMovementDate = latestMovementDate
    }
}

/// Un file già copiato e controllato, in attesa di conferma.
public struct ImportPreview: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Copia temporanea del file scelto.
    public let fileURL: URL
    public let current: DatabaseSummary
    public let incoming: DatabaseSummary

    public init(id: UUID = UUID(), fileURL: URL, current: DatabaseSummary, incoming: DatabaseSummary) {
        self.id = id
        self.fileURL = fileURL
        self.current = current
        self.incoming = incoming
    }

    /// I dati su questo dispositivo sono più recenti del file: importando si perdono modifiche.
    public var currentIsNewer: Bool {
        guard let currentDate = current.lastModifiedAt else { return false }
        guard let incomingDate = incoming.lastModifiedAt else { return true }
        return currentDate > incomingDate
    }

    /// Il file viene da un database creato altrove, non da una copia di questo.
    public var isDifferentDatabase: Bool {
        current.databaseID != incoming.databaseID
    }
}

/// Export e import del database (§ 10). Le feature non conoscono file e connessioni.
@MainActor
public protocol DataTransferring: AnyObject {
    var hasBackup: Bool { get }
    /// Crea una copia temporanea del database, cifrata se c'è una password.
    /// Va eliminata con `removeTemporaryFile`.
    func exportDatabase(password: String?) async throws -> URL
    /// Crea un CSV temporaneo. Va eliminato con `removeTemporaryFile`.
    func exportCSV() async throws -> URL
    func removeTemporaryFile(_ url: URL)
    /// Copia e controlla il file scelto, senza toccare i dati. Se è protetto e manca la password
    /// lancia `DataTransferError.passwordRequired`; se è sbagliata, `.wrongPassword`.
    func prepareImport(from source: URL, password: String?) async throws -> ImportPreview
    func cancelImport(_ preview: ImportPreview)
    /// Sostituisce il database. Restituisce il numero di movimenti importati, operazioni e trasferimenti.
    func performImport(_ preview: ImportPreview) async throws -> Int
    /// Ripristina l'ultima copia di sicurezza. Restituisce il numero di movimenti.
    func undoLastImport() async throws -> Int
}

/// Export CSV per Excel o Numbers (§ 10.5). Non è reimportabile.
public enum CSVDocument {
    public static let header = "data;tipo;importo;valuta;categoria;conto;nota"

    /// UTF-8 con BOM, senza il quale Excel sbaglia le lettere accentate.
    public static func data(for items: [OperationListItem]) -> Data {
        data(forMovements: items.map(MovementListItem.operation))
    }

    /// Un trasferimento è una riga sola: tipo "Trasferimento", nessuna categoria,
    /// conto "Conto A → Conto B" (§ 10.5).
    public static func data(forMovements movements: [MovementListItem]) -> Data {
        let rows = movements.map { movement in
            switch movement {
            case .operation(let item):
                let operation = item.operation
                return [
                    operation.date.string,
                    operation.kind == .income ? "Entrata" : "Uscita",
                    amountText(operation.amount),
                    operation.currency,
                    escaped(item.category.name),
                    escaped(item.accountName),
                    escaped(operation.note ?? ""),
                ].joined(separator: ";")
            case .transfer(let item):
                let transfer = item.transfer
                return [
                    transfer.date.string,
                    "Trasferimento",
                    amountText(transfer.amount),
                    transfer.currency,
                    "",
                    escaped(item.title),
                    escaped(transfer.note ?? ""),
                ].joined(separator: ";")
            }
        }
        let text = ([header] + rows).joined(separator: "\r\n") + "\r\n"
        return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
    }

    /// Sempre con la virgola decimale, qualunque sia la `Locale` (§ 10.5).
    static func amountText(_ minorUnits: Int64) -> String {
        AmountInput.text(minorUnits: minorUnits, locale: Locale(identifier: "it_IT"))
    }

    /// Virgolette dove servono. Un testo che inizia con `=`, `+`, `-` o `@` viene neutralizzato:
    /// Excel lo eseguirebbe come formula, e una nota può arrivare da un file importato.
    static func escaped(_ text: String) -> String {
        var value = text
        if let first = value.first, "=+-@\t\r".contains(first) {
            value = "'" + value
        }
        guard value.contains(where: { ";\"\n\r".contains($0) }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

public extension OperationRepository {
    /// Tutte le operazioni, per l'export.
    func allItems() async throws -> [OperationListItem] {
        try await observeItems(OperationQuery(limit: .max)).currentValue()
    }
}
