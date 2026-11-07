import Core
import Foundation
import Observation

/// Stato e regole dell'editor di un'operazione (§ 8.5). La vista si limita a mostrarli.
@MainActor
@Observable
public final class OperationEditorModel {
    public enum LoadState: Equatable {
        case loading
        case ready
        case failed
    }

    public let request: EditorRequest

    public var kind: OperationKind {
        didSet {
            guard kind != oldValue else { return }
            // Una categoria dell'altro tipo non è più valida (§ 8.5).
            if let categoryID, !visibleCategories.contains(where: { $0.id == categoryID }) {
                self.categoryID = nil
            }
        }
    }
    public var amountText = ""
    public var categoryID: CategoryID?
    public var date: Date
    public var accountID: AccountID?
    public var note = ""

    public private(set) var loadState = LoadState.loading
    public private(set) var isSaving = false
    public private(set) var saveFailed = false

    private var categories: [OperationCategory] = []
    private var accounts: [Account] = []
    /// Una categoria o un conto archiviati restano selezionabili per l'operazione che già li usa.
    private var originalCategoryID: CategoryID?
    private var originalAccountID: AccountID?
    private var initialSnapshot: Snapshot?

    private let operations: any OperationRepository
    private let categoryRepository: any CategoryRepository
    private let accountRepository: any AccountRepository
    private let calendar: Calendar

    public init(
        request: EditorRequest,
        operations: any OperationRepository,
        categories: any CategoryRepository,
        accounts: any AccountRepository,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        self.request = request
        self.operations = operations
        categoryRepository = categories
        accountRepository = accounts
        self.calendar = calendar
        date = now
        if case .new(let kind?) = request {
            self.kind = kind
        } else {
            kind = .expense
        }
    }

    // MARK: Dati mostrati

    public var isEditing: Bool {
        if case .edit = request { true } else { false }
    }

    public var visibleCategories: [OperationCategory] {
        categories.filter { $0.kind == kind && (!$0.isArchived || $0.id == originalCategoryID) }
    }

    public var visibleAccounts: [Account] {
        accounts.filter { !$0.isArchived || $0.id == originalAccountID }
    }

    /// Valuta del conto scelto, mostrata accanto all'importo.
    public var currency: String? {
        accounts.first { $0.id == accountID }?.currency
    }

    /// Con un solo conto il selettore è nascosto (§ 8.5).
    public var showsAccountPicker: Bool {
        visibleAccounts.count > 1
    }

    public var canSave: Bool {
        loadState == .ready && !isSaving && draft != nil
    }

    public var hasChanges: Bool {
        guard let initialSnapshot else { return false }
        return snapshot != initialSnapshot
    }

    // MARK: Azioni

    public func load() async {
        do {
            categories = try await firstValue(categoryRepository.observeCategories(includingArchived: true))
            accounts = try await firstValue(accountRepository.observeAccounts(includingArchived: true))

            switch request {
            case .new:
                accountID = visibleAccounts.first?.id
                categoryID = try await lastUsedCategory()
            case .edit(let id):
                guard let operation = try await operations.operation(id) else {
                    loadState = .failed
                    return
                }
                originalCategoryID = operation.categoryID
                originalAccountID = operation.accountID
                kind = operation.kind
                amountText = AmountInput.text(minorUnits: operation.amount)
                categoryID = operation.categoryID
                accountID = operation.accountID
                date = operation.date.date(in: calendar) ?? date
                note = operation.note ?? ""
            case .newTransfer, .editTransfer:
                // La radice apre `TransferEditorView` per queste richieste: qui non sono valide.
                loadState = .failed
                return
            }
            initialSnapshot = snapshot
            loadState = .ready
        } catch {
            loadState = .failed
        }
    }

    /// `true` se il salvataggio è riuscito e l'editor può chiudersi.
    public func save() async -> Bool {
        guard canSave, let draft else { return false }
        isSaving = true
        saveFailed = false
        defer { isSaving = false }
        do {
            switch request {
            case .new:
                try await operations.create(draft)
            case .edit(let id):
                try await operations.update(id, with: draft)
            case .newTransfer, .editTransfer:
                return false
            }
            return true
        } catch {
            saveFailed = true
            return false
        }
    }

    // MARK: Supporto

    private struct Snapshot: Equatable {
        let kind: OperationKind
        let amountText: String
        let categoryID: CategoryID?
        let day: Day
        let accountID: AccountID?
        let note: String
    }

    private var snapshot: Snapshot {
        Snapshot(
            kind: kind,
            amountText: amountText,
            categoryID: categoryID,
            day: Day(containing: date, calendar: calendar),
            accountID: accountID,
            note: note
        )
    }

    /// L'operazione da salvare, o `nil` se il modulo non è valido.
    private var draft: OperationDraft? {
        guard let amount = AmountInput.minorUnits(from: amountText),
              let categoryID, visibleCategories.contains(where: { $0.id == categoryID }),
              let accountID else { return nil }
        let draft = OperationDraft(
            kind: kind,
            amount: amount,
            date: Day(containing: date, calendar: calendar),
            accountID: accountID,
            categoryID: categoryID,
            note: note
        )
        return (try? draft.validate()) == nil ? nil : draft
    }

    /// Categoria dell'ultima operazione di questo tipo (§ 8.5), se non è stata archiviata.
    private func lastUsedCategory() async throws -> CategoryID? {
        let latest = try await firstValue(operations.observeItems(OperationQuery(kind: kind, limit: 1)))
        guard let id = latest.first?.operation.categoryID,
              visibleCategories.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private func firstValue<Value: Sendable>(_ stream: AsyncThrowingStream<Value, any Error>) async throws -> Value {
        for try await value in stream {
            return value
        }
        throw CancellationError()
    }
}
