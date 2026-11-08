import Core
import Foundation
import Persistence
import Testing
@testable import OperationEditorFeature

@MainActor
struct TransferEditorModelTests {
    let database: AppDatabase
    let today: Date
    let calendar: Calendar
    let main: Account
    let savings: Account

    init() async throws {
        database = try AppDatabase.inMemory()
        try await database.seedIfNeeded(currency: "EUR")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Rome"))
        self.calendar = calendar
        today = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12)))

        var iterator = database.accounts.observeAccounts(includingArchived: false).makeAsyncIterator()
        main = try #require(try await iterator.next()?.first)
        savings = try await database.accounts.create(name: "Risparmi", currency: "EUR", initialBalance: 50000)
    }

    /// Come lo sheet della radice: una richiesta di trasferimento diventa il modello dell'editor.
    func makeModel(_ request: EditorRequest) async throws -> TransferEditorModel {
        let model: TransferEditorModel
        switch request {
        case .newTransfer(let account):
            model = TransferEditorModel(
                from: account, transfers: database.transfers, movements: database.movements, now: today, calendar: calendar
            )
        case .editTransfer(let id):
            model = TransferEditorModel(
                transferID: id, transfers: database.transfers, movements: database.movements, now: today, calendar: calendar
            )
        case .new, .edit:
            Issue.record("Non è una richiesta di trasferimento")
            throw CancellationError()
        }
        await model.load()
        return model
    }

    func allTransfers() async throws -> [AccountTransfer] {
        var iterator = database.movements.observeMovements(MovementQuery(kind: .transfer)).makeAsyncIterator()
        let items = try #require(try await iterator.next())
        return items.compactMap { item -> AccountTransfer? in
            guard case .transfer(let transfer) = item else { return nil }
            return transfer.transfer
        }
    }

    // MARK: Richieste

    @Test func operationRequestsAreNotTransfers() {
        for request in [EditorRequest.new(kind: nil), .edit(OperationID())] {
            #expect(!request.isTransfer)
        }
        #expect(EditorRequest.newTransfer(from: nil).isTransfer)
        #expect(EditorRequest.editTransfer(TransferID()).isTransfer)
    }

    // MARK: Valori iniziali

    @Test func newTransferDefaults() async throws {
        let model = try await makeModel(.newTransfer(from: nil))
        #expect(model.loadState == .ready)
        #expect(!model.isEditing)
        #expect(model.fromAccountID == main.id)
        #expect(model.toAccountID == savings.id)
        #expect(model.date == today)
        #expect(model.currency == "EUR")
        #expect(!model.hasTooFewAccounts)
        #expect(!model.hasChanges)
        #expect(!model.canSave, "Manca l'importo")
    }

    @Test func startsFromRequestedAccount() async throws {
        let model = try await makeModel(.newTransfer(from: savings.id))
        #expect(model.fromAccountID == savings.id)
        #expect(model.toAccountID == main.id)
        #expect(!model.hasChanges, "Il conto proposto non è una modifica")
    }

    @Test func singleAccountIsNotEnough() async throws {
        try await database.accounts.setArchived(savings.id, isArchived: true)
        let model = try await makeModel(.newTransfer(from: nil))
        #expect(model.hasTooFewAccounts)
        #expect(!model.canSave)
    }

    @Test func showsBalancesOfAccounts() async throws {
        let model = try await makeModel(.newTransfer(from: nil))
        #expect(model.balance(of: savings.id) == 50000)
        #expect(model.balance(of: main.id) == 0)
    }

    // MARK: Conti

    @Test func destinationExcludesSource() async throws {
        let model = try await makeModel(.newTransfer(from: nil))
        #expect(!model.destinationAccounts.contains { $0.id == model.fromAccountID })
    }

    @Test func choosingDestinationAsSourceMovesDestination() async throws {
        let model = try await makeModel(.newTransfer(from: nil))
        model.fromAccountID = savings.id
        #expect(model.toAccountID == main.id)
        #expect(model.fromAccountID != model.toAccountID)
    }

    @Test func swapExchangesAccounts() async throws {
        let model = try await makeModel(.newTransfer(from: nil))
        model.swapAccounts()
        #expect(model.fromAccountID == savings.id)
        #expect(model.toAccountID == main.id)
        #expect(model.hasChanges)
    }

    @Test func archivedAccountsAreHiddenForNewTransfers() async throws {
        let old = try await database.accounts.create(name: "Vecchio", currency: "EUR", initialBalance: 0)
        try await database.accounts.setArchived(old.id, isArchived: true)
        let model = try await makeModel(.newTransfer(from: old.id))
        #expect(!model.visibleAccounts.contains { $0.id == old.id })
        #expect(model.fromAccountID == main.id, "Un conto archiviato non si propone come origine")
    }

    // MARK: Validazione e avvisi

    @Test(arguments: ["", "0", "abc", "1,234"])
    func invalidAmountCannotBeSaved(amount: String) async throws {
        let model = try await makeModel(.newTransfer(from: nil))
        model.amountText = amount
        #expect(!model.canSave)
    }

    @Test func noteTooLongCannotBeSaved() async throws {
        let model = try await makeModel(.newTransfer(from: nil))
        model.amountText = "10"
        model.note = String(repeating: "a", count: 201)
        #expect(!model.canSave)
    }

    @Test func warnsWhenAmountExceedsBalanceButAllowsSaving() async throws {
        let model = try await makeModel(.newTransfer(from: savings.id))
        model.amountText = "500"
        #expect(!model.exceedsAvailableBalance)
        model.amountText = "500,01"
        #expect(model.exceedsAvailableBalance)
        #expect(model.canSave)
    }

    // MARK: Salvataggio

    @Test func savesNewTransfer() async throws {
        let model = try await makeModel(.newTransfer(from: savings.id))
        model.amountText = "120,50"
        model.note = "  spesa casa "
        #expect(model.hasChanges)
        #expect(await model.save())

        let saved = try #require(try await allTransfers().first)
        #expect(saved.amount == 12050)
        #expect(saved.fromAccountID == savings.id)
        #expect(saved.toAccountID == main.id)
        #expect(saved.date == Day(year: 2026, month: 11, day: 7))
        #expect(saved.note == "spesa casa")
    }

    @Test func editLoadsAndUpdatesTransfer() async throws {
        let created = try await database.transfers.create(TransferDraft(
            amount: 30000,
            date: try #require(Day(year: 2026, month: 11, day: 1)),
            fromAccountID: savings.id,
            toAccountID: main.id,
            note: "affitto"
        ))
        let model = try await makeModel(.editTransfer(created.id))
        #expect(model.isEditing)
        #expect(model.amountText == AmountInput.text(minorUnits: 30000))
        #expect(model.fromAccountID == savings.id)
        #expect(model.toAccountID == main.id)
        #expect(model.note == "affitto")
        #expect(!model.hasChanges)

        // Il trasferimento stesso torna disponibile: sul conto c'erano 500 € prima di spostarne 300.
        #expect(model.availableBalance == 50000)
        model.amountText = "400"
        #expect(!model.exceedsAvailableBalance)

        #expect(await model.save())
        #expect(try await database.transfers.transfer(created.id)?.amount == 40000)
    }

    @Test func editKeepsArchivedAccountOfTheTransfer() async throws {
        let old = try await database.accounts.create(name: "Vecchio", currency: "EUR", initialBalance: 0)
        let created = try await database.transfers.create(TransferDraft(
            amount: 100,
            date: try #require(Day(year: 2026, month: 11, day: 1)),
            fromAccountID: main.id,
            toAccountID: old.id
        ))
        try await database.accounts.setArchived(old.id, isArchived: true)

        let model = try await makeModel(.editTransfer(created.id))
        #expect(model.visibleAccounts.contains { $0.id == old.id })
        #expect(model.toAccountID == old.id)
        model.note = "chiusura"
        #expect(await model.save())
    }

    @Test func missingTransferFailsToLoad() async throws {
        let model = try await makeModel(.editTransfer(TransferID()))
        #expect(model.loadState == .failed)
        #expect(!model.canSave)
    }
}
