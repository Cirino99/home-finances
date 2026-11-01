/// Le feature dipendono da questi protocolli, mai da GRDB (§ 4).
/// Le scritture sono `async`; le letture reattive emettono subito il valore attuale e poi ogni cambiamento.

public enum RepositoryError: Error, Equatable {
    case notFound
    /// Il tipo dell'operazione non coincide con quello della categoria (§ 6.2).
    case kindMismatch
    case nameEmpty
}

public protocol OperationRepository: Sendable {
    @discardableResult
    func create(_ draft: OperationDraft) async throws -> FinanceOperation
    @discardableResult
    func update(_ id: OperationID, with draft: OperationDraft) async throws -> FinanceOperation
    func delete(_ id: OperationID) async throws
    func operation(_ id: OperationID) async throws -> FinanceOperation?

    func observeItem(_ id: OperationID) -> AsyncThrowingStream<OperationListItem?, any Error>
    func observeItems(_ query: OperationQuery) -> AsyncThrowingStream<[OperationListItem], any Error>
    /// Ultime operazioni in assoluto, per data e poi per creazione.
    func observeRecent(limit: Int) -> AsyncThrowingStream<[OperationListItem], any Error>
    func observeTotals(for month: YearMonth) -> AsyncThrowingStream<PeriodTotals, any Error>
    /// Mesi con almeno un'operazione, dal più recente; solo di `year` se indicato.
    func observeMonthlyTotals(year: Int?) -> AsyncThrowingStream<[MonthTotals], any Error>
    /// Anni con almeno un'operazione, dal più recente.
    func observeYearlyTotals() -> AsyncThrowingStream<[YearTotals], any Error>
}

public protocol CategoryRepository: Sendable {
    @discardableResult
    func create(name: String, kind: OperationKind, symbol: String, color: CategoryColor) async throws -> OperationCategory
    /// Il tipo non cambia: le operazioni collegate devono restare coerenti.
    func update(_ id: CategoryID, name: String, symbol: String, color: CategoryColor) async throws
    func setArchived(_ id: CategoryID, isArchived: Bool) async throws
    /// L'ordine dell'array diventa `sort_order`.
    func reorder(_ ids: [CategoryID]) async throws
    /// Cancella la categoria, o la archivia se ha operazioni collegate.
    func remove(_ id: CategoryID) async throws -> RemovalOutcome

    func observeCategories(includingArchived: Bool) -> AsyncThrowingStream<[OperationCategory], any Error>
}

public protocol AccountRepository: Sendable {
    @discardableResult
    func create(name: String, currency: String, initialBalance: Int64) async throws -> Account
    func update(_ id: AccountID, name: String, initialBalance: Int64) async throws
    func setArchived(_ id: AccountID, isArchived: Bool) async throws
    /// L'ordine dell'array diventa `sort_order`.
    func reorder(_ ids: [AccountID]) async throws
    /// Cancella il conto, o lo archivia se ha operazioni collegate.
    func remove(_ id: AccountID) async throws -> RemovalOutcome

    func observeAccounts(includingArchived: Bool) -> AsyncThrowingStream<[Account], any Error>
}
