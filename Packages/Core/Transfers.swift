import Foundation

public typealias TransferID = EntityID<AccountTransfer>

/// Spostamento di liquidità da un conto a un altro (§ 6.2, migrazione `v2`).
/// Non è né un'entrata né un'uscita: non entra nei totali del mese (§ 6.4).
public struct AccountTransfer: Identifiable, Equatable, Sendable {
    public let id: TransferID
    /// Unità minori, sempre positive.
    public var amount: Int64
    /// Valuta del conto di origine, uguale a quella di destinazione.
    public var currency: String
    public var date: Day
    public var fromAccountID: AccountID
    public var toAccountID: AccountID
    public var note: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: TransferID,
        amount: Int64,
        currency: String,
        date: Day,
        fromAccountID: AccountID,
        toAccountID: AccountID,
        note: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.amount = amount
        self.currency = currency
        self.date = date
        self.fromAccountID = fromAccountID
        self.toAccountID = toAccountID
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Importo visto da `account`: negativo se esce, positivo se entra.
    /// `nil` se il conto non c'entra o non è indicato: senza un conto di riferimento un trasferimento non ha segno.
    public func signedAmount(for account: AccountID?) -> Int64? {
        if account == fromAccountID {
            -amount
        } else if account == toAccountID {
            amount
        } else {
            nil
        }
    }
}

public enum TransferDraftError: Error, Equatable {
    case amountNotPositive
    case sameAccount
    case noteTooLong
}

/// Contenuto di un trasferimento da creare o modificare, con le regole dell'editor (§ 8.8).
public struct TransferDraft: Equatable, Sendable {
    public static let maxNoteLength = OperationDraft.maxNoteLength

    public var amount: Int64
    public var date: Day
    public var fromAccountID: AccountID
    public var toAccountID: AccountID
    public var note: String?

    public init(amount: Int64, date: Day, fromAccountID: AccountID, toAccountID: AccountID, note: String? = nil) {
        self.amount = amount
        self.date = date
        self.fromAccountID = fromAccountID
        self.toAccountID = toAccountID
        self.note = note
    }

    /// Nota senza spazi ai bordi; vuota diventa `nil`.
    public var normalizedNote: String? {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    public func validate() throws {
        guard amount > 0 else { throw TransferDraftError.amountNotPositive }
        guard fromAccountID != toAccountID else { throw TransferDraftError.sameAccount }
        guard (normalizedNote?.count ?? 0) <= Self.maxNoteLength else { throw TransferDraftError.noteTooLong }
    }

    /// "Inverti" dell'editor: origine e destinazione si scambiano.
    public mutating func swapAccounts() {
        swap(&fromAccountID, &toAccountID)
    }
}

/// Riga di un elenco: il trasferimento con i nomi dei due conti.
public struct TransferListItem: Identifiable, Equatable, Sendable {
    public let transfer: AccountTransfer
    public let fromAccountName: String
    public let toAccountName: String

    public init(transfer: AccountTransfer, fromAccountName: String, toAccountName: String) {
        self.transfer = transfer
        self.fromAccountName = fromAccountName
        self.toAccountName = toAccountName
    }

    public var id: TransferID { transfer.id }

    /// "Conto A → Conto B", titolo della riga e colonna `conto` del CSV (§ 8.8, § 10.5).
    public var title: String {
        "\(fromAccountName) → \(toAccountName)"
    }
}

// MARK: Movimenti

/// Identificatore di una riga dello Storico, che può essere un'operazione o un trasferimento.
public enum MovementID: Hashable, Sendable {
    case operation(OperationID)
    case transfer(TransferID)
}

/// Un movimento degli elenchi: operazione o trasferimento (§ 8.3).
public enum MovementListItem: Identifiable, Equatable, Sendable {
    case operation(OperationListItem)
    case transfer(TransferListItem)

    public var id: MovementID {
        switch self {
        case .operation(let item): .operation(item.id)
        case .transfer(let item): .transfer(item.id)
        }
    }

    public var date: Day {
        switch self {
        case .operation(let item): item.operation.date
        case .transfer(let item): item.transfer.date
        }
    }

    public var createdAt: Date {
        switch self {
        case .operation(let item): item.operation.createdAt
        case .transfer(let item): item.transfer.createdAt
        }
    }

    public var currency: String {
        switch self {
        case .operation(let item): item.operation.currency
        case .transfer(let item): item.transfer.currency
        }
    }

    /// Importo con segno: per un'operazione dipende dal tipo, per un trasferimento dal conto
    /// di riferimento (§ 8.3). `nil` per un trasferimento senza conto di riferimento.
    public func signedAmount(for account: AccountID?) -> Int64? {
        switch self {
        case .operation(let item):
            item.operation.kind == .income ? item.operation.amount : -item.operation.amount
        case .transfer(let item):
            item.transfer.signedAmount(for: account)
        }
    }
}

/// Tipo di movimento per il filtro dello Storico: Entrate, Uscite, Trasferimenti (§ 8.3).
public enum MovementKind: String, Sendable, CaseIterable {
    case income
    case expense
    case transfer

    public init(_ kind: OperationKind) {
        switch kind {
        case .income: self = .income
        case .expense: self = .expense
        }
    }

    /// Il tipo di operazione corrispondente; `nil` per i trasferimenti.
    public var operationKind: OperationKind? {
        switch self {
        case .income: .income
        case .expense: .expense
        case .transfer: nil
        }
    }
}

/// Filtri, ricerca e pagina dell'elenco dei movimenti (§ 8.3).
public struct MovementQuery: Equatable, Sendable {
    public static let defaultPageSize = OperationQuery.defaultPageSize

    public var month: YearMonth?
    /// Cerca nella nota, nel nome della categoria e nei nomi dei conti di un trasferimento.
    public var searchText: String?
    public var kind: MovementKind?
    public var categoryID: CategoryID?
    /// Operazioni del conto e trasferimenti in cui il conto è origine o destinazione.
    public var accountID: AccountID?
    public var limit: Int
    public var offset: Int

    public init(
        month: YearMonth? = nil,
        searchText: String? = nil,
        kind: MovementKind? = nil,
        categoryID: CategoryID? = nil,
        accountID: AccountID? = nil,
        limit: Int = MovementQuery.defaultPageSize,
        offset: Int = 0
    ) {
        self.month = month
        self.searchText = searchText
        self.kind = kind
        self.categoryID = categoryID
        self.accountID = accountID
        self.limit = limit
        self.offset = offset
    }

    public var includesOperations: Bool {
        kind != .transfer
    }

    /// Una categoria scelta esclude i trasferimenti, che non ne hanno.
    public var includesTransfers: Bool {
        (kind == nil || kind == .transfer) && categoryID == nil
    }
}

// MARK: Saldi

/// Saldo di un conto e i movimenti che lo compongono (§ 6.4). Contano tutti, anche quelli con data futura.
public struct AccountBalance: Identifiable, Equatable, Sendable {
    public let account: Account
    public let income: Int64
    public let expense: Int64
    /// Trasferimenti ricevuti.
    public let received: Int64
    /// Trasferimenti inviati.
    public let sent: Int64

    public init(account: Account, income: Int64 = 0, expense: Int64 = 0, received: Int64 = 0, sent: Int64 = 0) {
        self.account = account
        self.income = income
        self.expense = expense
        self.received = received
        self.sent = sent
    }

    public var id: AccountID { account.id }

    /// Saldo iniziale + entrate − uscite + trasferimenti ricevuti − trasferimenti inviati.
    public var balance: Int64 {
        account.initialBalance + income - expense + received - sent
    }

    /// Saldo totale: tutti i conti, archiviati compresi (§ 6.4).
    public static func total(of balances: [AccountBalance]) -> Int64 {
        balances.reduce(0) { $0 + $1.balance }
    }
}
