import Core
import Foundation
import Observation

/// Stato e regole dell'editor di un trasferimento (§ 8.8). La vista si limita a mostrarli.
@MainActor
@Observable
public final class TransferEditorModel {
    public enum LoadState: Equatable {
        case loading
        case ready
        case failed
    }

    /// Il trasferimento da modificare; `nil` per uno nuovo.
    public let transferID: TransferID?

    public var amountText = ""
    public var fromAccountID: AccountID? {
        didSet {
            // Origine e destinazione devono restare diverse: la destinazione passa a un altro conto.
            if fromAccountID != nil, toAccountID == fromAccountID {
                toAccountID = destinationAccounts.first?.id
            }
        }
    }
    public var toAccountID: AccountID?
    public var date: Date
    public var note = ""

    public private(set) var loadState = LoadState.loading
    public private(set) var isSaving = false
    public private(set) var saveFailed = false

    private var balances: [AccountBalance] = []
    /// Il trasferimento come era prima della modifica: i suoi conti restano selezionabili anche
    /// se archiviati, e il suo importo torna disponibile sul conto di origine.
    private var original: AccountTransfer?
    private var initialSnapshot: Snapshot?

    private let requestedSource: AccountID?
    private let transfers: any TransferRepository
    private let movements: any MovementRepository
    private let calendar: Calendar

    public init(
        transferID: TransferID? = nil,
        from account: AccountID? = nil,
        transfers: any TransferRepository,
        movements: any MovementRepository,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        self.transferID = transferID
        requestedSource = account
        self.transfers = transfers
        self.movements = movements
        self.calendar = calendar
        date = now
    }

    /// Per lo sheet della radice: `nil` se la richiesta non riguarda un trasferimento.
    public convenience init?(
        request: EditorRequest,
        transfers: any TransferRepository,
        movements: any MovementRepository,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        switch request {
        case .newTransfer(let account):
            self.init(from: account, transfers: transfers, movements: movements, now: now, calendar: calendar)
        case .editTransfer(let id):
            self.init(transferID: id, transfers: transfers, movements: movements, now: now, calendar: calendar)
        case .new, .edit:
            return nil
        }
    }

    // MARK: Dati mostrati

    public var isEditing: Bool {
        transferID != nil
    }

    /// Conti attivi, più quelli archiviati già usati dal trasferimento in modifica (§ 8.8).
    public var visibleAccounts: [Account] {
        balances.map(\.account).filter { account in
            !account.isArchived || account.id == original?.fromAccountID || account.id == original?.toAccountID
        }
    }

    /// "A": tutti tranne il conto di origine.
    public var destinationAccounts: [Account] {
        visibleAccounts.filter { $0.id != fromAccountID }
    }

    /// Con meno di due conti non c'è nulla da trasferire.
    public var hasTooFewAccounts: Bool {
        loadState == .ready && visibleAccounts.count < 2
    }

    /// Valuta del conto di origine, mostrata accanto all'importo.
    public var currency: String? {
        visibleAccounts.first { $0.id == fromAccountID }?.currency
    }

    /// Saldo di un conto, mostrato nei selettori.
    public func balance(of account: AccountID) -> Int64? {
        balances.first { $0.account.id == account }?.balance
    }

    /// Quanto c'è sul conto di origine prima di questo trasferimento: in modifica il saldo
    /// comprende già il trasferimento stesso, che va tolto dal conto.
    public var availableBalance: Int64? {
        guard let fromAccountID, var available = balance(of: fromAccountID) else { return nil }
        if let original {
            if original.fromAccountID == fromAccountID { available += original.amount }
            if original.toAccountID == fromAccountID { available -= original.amount }
        }
        return available
    }

    /// L'importo supera il saldo dell'origine: si avvisa, ma si può salvare (§ 8.8).
    public var exceedsAvailableBalance: Bool {
        guard let amount = AmountInput.minorUnits(from: amountText), let availableBalance else { return false }
        return amount > availableBalance
    }

    public var canSave: Bool {
        loadState == .ready && !isSaving && draft != nil
    }

    public var hasChanges: Bool {
        guard let initialSnapshot else { return false }
        return snapshot != initialSnapshot
    }

    // MARK: Azioni

    /// "Inverti": origine e destinazione si scambiano.
    public func swapAccounts() {
        let previousFrom = fromAccountID
        let previousTo = toAccountID
        // Prima la destinazione: assegnare l'origine non deve trovarla uguale e spostarla.
        toAccountID = nil
        fromAccountID = previousTo
        toAccountID = previousFrom
    }

    public func load() async {
        do {
            balances = try await firstValue(movements.observeBalances())
            if let transferID {
                guard let transfer = try await transfers.transfer(transferID) else {
                    loadState = .failed
                    return
                }
                original = transfer
                amountText = AmountInput.text(minorUnits: transfer.amount)
                fromAccountID = transfer.fromAccountID
                toAccountID = transfer.toAccountID
                date = transfer.date.date(in: calendar) ?? date
                note = transfer.note ?? ""
            } else {
                let source = visibleAccounts.first { $0.id == requestedSource } ?? visibleAccounts.first
                fromAccountID = source?.id
                toAccountID = destinationAccounts.first?.id
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
            if let transferID {
                try await transfers.update(transferID, with: draft)
            } else {
                try await transfers.create(draft)
            }
            return true
        } catch {
            saveFailed = true
            return false
        }
    }

    // MARK: Supporto

    private struct Snapshot: Equatable {
        let amountText: String
        let fromAccountID: AccountID?
        let toAccountID: AccountID?
        let day: Day
        let note: String
    }

    private var snapshot: Snapshot {
        Snapshot(
            amountText: amountText,
            fromAccountID: fromAccountID,
            toAccountID: toAccountID,
            day: Day(containing: date, calendar: calendar),
            note: note
        )
    }

    /// Il trasferimento da salvare, o `nil` se il modulo non è valido.
    private var draft: TransferDraft? {
        let visible = Set(visibleAccounts.map(\.id))
        guard let amount = AmountInput.minorUnits(from: amountText),
              let fromAccountID, visible.contains(fromAccountID),
              let toAccountID, visible.contains(toAccountID) else { return nil }
        let draft = TransferDraft(
            amount: amount,
            date: Day(containing: date, calendar: calendar),
            fromAccountID: fromAccountID,
            toAccountID: toAccountID,
            note: note
        )
        return (try? draft.validate()) == nil ? nil : draft
    }

    private func firstValue<Value: Sendable>(_ stream: AsyncThrowingStream<Value, any Error>) async throws -> Value {
        for try await value in stream {
            return value
        }
        throw CancellationError()
    }
}
