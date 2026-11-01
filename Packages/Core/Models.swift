import Foundation

/// Identificatore tipizzato: un `AccountID` non si può passare dove serve un `CategoryID`.
public struct EntityID<Entity>: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public typealias AccountID = EntityID<Account>
public typealias CategoryID = EntityID<OperationCategory>
public typealias OperationID = EntityID<FinanceOperation>

public struct Account: Identifiable, Equatable, Sendable {
    public let id: AccountID
    public var name: String
    public var currency: String
    /// Unità minori, può essere negativo.
    public var initialBalance: Int64
    public var isArchived: Bool
    public var sortOrder: Int
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: AccountID,
        name: String,
        currency: String,
        initialBalance: Int64,
        isArchived: Bool,
        sortOrder: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.currency = currency
        self.initialBalance = initialBalance
        self.isArchived = isArchived
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Token colore delle categorie: il DesignSystem li traduce in colori.
public enum CategoryColor: String, CaseIterable, Sendable {
    case gray, red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, brown
}

/// "Categoria" di un'operazione. Il nome evita il tipo `Category` del runtime Objective-C.
public struct OperationCategory: Identifiable, Equatable, Sendable {
    public let id: CategoryID
    public var name: String
    /// Non modificabile dopo la creazione: le operazioni collegate devono restare coerenti (§ 6.2).
    public let kind: OperationKind
    /// Nome di un SF Symbol.
    public var symbol: String
    public var color: CategoryColor
    public var isArchived: Bool
    public var sortOrder: Int
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: CategoryID,
        name: String,
        kind: OperationKind,
        symbol: String,
        color: CategoryColor,
        isArchived: Bool,
        sortOrder: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.symbol = symbol
        self.color = color
        self.isArchived = isArchived
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Un'entrata o un'uscita. Il nome evita `Foundation.Operation`.
public struct FinanceOperation: Identifiable, Equatable, Sendable {
    public let id: OperationID
    public var kind: OperationKind
    /// Unità minori, sempre positive: il segno dipende da `kind`.
    public var amount: Int64
    public var currency: String
    public var date: Day
    public var accountID: AccountID
    public var categoryID: CategoryID
    public var note: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: OperationID,
        kind: OperationKind,
        amount: Int64,
        currency: String,
        date: Day,
        accountID: AccountID,
        categoryID: CategoryID,
        note: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.amount = amount
        self.currency = currency
        self.date = date
        self.accountID = accountID
        self.categoryID = categoryID
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum OperationDraftError: Error, Equatable {
    case amountNotPositive
    case noteTooLong
}

/// Contenuto di un'operazione da creare o modificare, con le regole dell'editor (§ 8.5).
public struct OperationDraft: Equatable, Sendable {
    public static let maxNoteLength = 200

    public var kind: OperationKind
    public var amount: Int64
    public var date: Day
    public var accountID: AccountID
    public var categoryID: CategoryID
    public var note: String?

    public init(
        kind: OperationKind,
        amount: Int64,
        date: Day,
        accountID: AccountID,
        categoryID: CategoryID,
        note: String? = nil
    ) {
        self.kind = kind
        self.amount = amount
        self.date = date
        self.accountID = accountID
        self.categoryID = categoryID
        self.note = note
    }

    /// Nota senza spazi ai bordi; vuota diventa `nil`.
    public var normalizedNote: String? {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    public func validate() throws {
        guard amount > 0 else { throw OperationDraftError.amountNotPositive }
        guard (normalizedNote?.count ?? 0) <= Self.maxNoteLength else { throw OperationDraftError.noteTooLong }
    }
}

/// Entrate e uscite di un periodo, sempre positive.
public struct PeriodTotals: Equatable, Sendable {
    public var income: Int64
    public var expense: Int64

    public init(income: Int64 = 0, expense: Int64 = 0) {
        self.income = income
        self.expense = expense
    }

    /// Entrate − uscite (§ 6.4).
    public var balance: Int64 {
        income - expense
    }
}

public struct MonthTotals: Equatable, Sendable {
    public let month: YearMonth
    public let totals: PeriodTotals

    public init(month: YearMonth, totals: PeriodTotals) {
        self.month = month
        self.totals = totals
    }
}

public struct YearTotals: Equatable, Sendable {
    public let year: Int
    public let totals: PeriodTotals

    public init(year: Int, totals: PeriodTotals) {
        self.year = year
        self.totals = totals
    }
}

/// Riga di un elenco: l'operazione con ciò che serve a mostrarla.
public struct OperationListItem: Identifiable, Equatable, Sendable {
    public let operation: FinanceOperation
    public let category: OperationCategory
    public let accountName: String

    public init(operation: FinanceOperation, category: OperationCategory, accountName: String) {
        self.operation = operation
        self.category = category
        self.accountName = accountName
    }

    public var id: OperationID { operation.id }
}

/// Filtri, ricerca e pagina di Storico › Operazioni (§ 8.3).
public struct OperationQuery: Equatable, Sendable {
    public static let defaultPageSize = 100

    public var month: YearMonth?
    /// Cerca in nota e nome della categoria.
    public var searchText: String?
    public var kind: OperationKind?
    public var categoryID: CategoryID?
    public var accountID: AccountID?
    public var limit: Int
    public var offset: Int

    public init(
        month: YearMonth? = nil,
        searchText: String? = nil,
        kind: OperationKind? = nil,
        categoryID: CategoryID? = nil,
        accountID: AccountID? = nil,
        limit: Int = OperationQuery.defaultPageSize,
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
}

/// Esito della rimozione di una categoria o di un conto (§ 6.1).
public enum RemovalOutcome: Equatable, Sendable {
    case deleted
    /// Ha operazioni collegate: è stato archiviato.
    case archived
}
