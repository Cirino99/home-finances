/// Le feature dipendono da questi protocolli, mai da GRDB (§ 4).
/// Le scritture sono `async`; le letture reattive emettono subito il valore attuale e poi ogni cambiamento.

public enum RepositoryError: Error, Equatable {
    case notFound
    /// Il tipo dell'operazione non coincide con quello della categoria (§ 6.2).
    case kindMismatch
    case nameEmpty
    /// Serve sempre almeno un conto attivo su cui registrare le operazioni.
    case lastActiveAccount
    /// I due conti di un trasferimento hanno valute diverse.
    case currencyMismatch
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
    /// Lancia `lastActiveAccount` se si archivia l'ultimo conto attivo.
    func setArchived(_ id: AccountID, isArchived: Bool) async throws
    /// L'ordine dell'array diventa `sort_order`.
    func reorder(_ ids: [AccountID]) async throws
    /// Cancella il conto, o lo archivia se ha operazioni o trasferimenti collegati.
    /// Lancia `lastActiveAccount` se è l'ultimo conto attivo.
    func remove(_ id: AccountID) async throws -> RemovalOutcome

    func observeAccounts(includingArchived: Bool) -> AsyncThrowingStream<[Account], any Error>
}

/// Trasferimenti tra conti (§ 8.8).
public protocol TransferRepository: Sendable {
    /// Lancia `TransferDraftError` se la bozza non è valida, `RepositoryError.notFound` se un conto non esiste,
    /// `RepositoryError.currencyMismatch` se i conti hanno valute diverse.
    @discardableResult
    func create(_ draft: TransferDraft) async throws -> AccountTransfer
    @discardableResult
    func update(_ id: TransferID, with draft: TransferDraft) async throws -> AccountTransfer
    func delete(_ id: TransferID) async throws
    func transfer(_ id: TransferID) async throws -> AccountTransfer?

    func observeItem(_ id: TransferID) -> AsyncThrowingStream<TransferListItem?, any Error>
}

/// Letture che uniscono operazioni e trasferimenti: elenchi dei movimenti e saldi dei conti (§ 6.3).
public protocol MovementRepository: Sendable {
    /// Ordinati per data, poi per creazione, poi per id: l'ordine resta stabile tra le pagine.
    func observeMovements(_ query: MovementQuery) -> AsyncThrowingStream<[MovementListItem], any Error>
    /// Saldi di tutti i conti, archiviati compresi, nell'ordine dei conti.
    func observeBalances() -> AsyncThrowingStream<[AccountBalance], any Error>
}

public extension MovementRepository {
    /// Ultimi movimenti in assoluto, oppure di un conto (§ 8.2, § 8.7).
    func observeRecentMovements(limit: Int, account: AccountID? = nil) -> AsyncThrowingStream<[MovementListItem], any Error> {
        observeMovements(MovementQuery(accountID: account, limit: limit))
    }

    /// Tutti i movimenti, per l'export CSV.
    func allMovements() async throws -> [MovementListItem] {
        for try await items in observeMovements(MovementQuery(limit: .max)) {
            return items
        }
        return []
    }
}
