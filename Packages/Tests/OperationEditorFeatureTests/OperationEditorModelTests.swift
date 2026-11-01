import Core
import Foundation
import Persistence
import Testing
@testable import OperationEditorFeature

@MainActor
struct OperationEditorModelTests {
    let database: AppDatabase
    let today: Date
    let calendar: Calendar

    init() async throws {
        database = try AppDatabase.inMemory()
        try await database.seedIfNeeded(currency: "EUR")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Rome"))
        self.calendar = calendar
        today = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12)))
    }

    func makeModel(_ request: EditorRequest) async -> OperationEditorModel {
        let model = OperationEditorModel(
            request: request,
            operations: database.operations,
            categories: database.categories,
            accounts: database.accounts,
            now: today,
            calendar: calendar
        )
        await model.load()
        return model
    }

    func firstValue<Value: Sendable>(_ stream: AsyncThrowingStream<Value, any Error>) async throws -> Value {
        for try await value in stream {
            return value
        }
        throw CancellationError()
    }

    /// Modulo valido con la prima categoria del tipo corrente.
    func fill(_ model: OperationEditorModel, amount: String = "12,50") {
        model.amountText = amount
        model.categoryID = model.visibleCategories.first?.id
    }

    // MARK: Valori iniziali

    @Test func newOperationDefaults() async {
        let model = await makeModel(.new(kind: nil))
        #expect(model.loadState == .ready)
        #expect(model.kind == .expense)
        #expect(model.date == today)
        #expect(model.currency == "EUR")
        #expect(model.categoryID == nil)
        #expect(model.accountID != nil)
        #expect(!model.showsAccountPicker, "Con un solo conto il selettore è nascosto")
        #expect(!model.hasChanges)
        #expect(!model.canSave)
    }

    @Test func quickAddSetsKind() async {
        let model = await makeModel(.new(kind: .income))
        #expect(model.kind == .income)
        #expect(model.visibleCategories.allSatisfy { $0.kind == .income })
    }

    @Test func defaultCategoryIsLastUsedForThatKind() async throws {
        let first = await makeModel(.new(kind: .expense))
        fill(first)
        let lastCategory = try #require(first.visibleCategories.last?.id)
        first.categoryID = lastCategory
        #expect(await first.save())

        let sameKind = await makeModel(.new(kind: .expense))
        #expect(sameKind.categoryID == lastCategory)
        #expect(!sameKind.hasChanges, "Il valore proposto non è una modifica")

        let otherKind = await makeModel(.new(kind: .income))
        #expect(otherKind.categoryID == nil)
    }

    // MARK: Validazione

    @Test(arguments: ["", "0", "0,00", "abc", "12,345"])
    func invalidAmountsPreventSaving(amount: String) async {
        let model = await makeModel(.new(kind: nil))
        fill(model, amount: amount)
        #expect(!model.canSave)
    }

    @Test func categoryIsRequired() async {
        let model = await makeModel(.new(kind: nil))
        fill(model)
        #expect(model.canSave)
        model.categoryID = nil
        #expect(!model.canSave)
    }

    @Test func noteHasMaximumLength() async {
        let model = await makeModel(.new(kind: nil))
        fill(model)
        model.note = String(repeating: "a", count: OperationDraft.maxNoteLength)
        #expect(model.canSave)
        model.note += "a"
        #expect(!model.canSave)
    }

    @Test func changingKindResetsIncompatibleCategory() async {
        let model = await makeModel(.new(kind: .expense))
        fill(model)
        #expect(model.categoryID != nil)

        model.kind = .income
        #expect(model.categoryID == nil)
        #expect(!model.canSave)
    }

    // MARK: Salvataggio

    @Test func savesNewOperation() async throws {
        let model = await makeModel(.new(kind: .expense))
        fill(model)
        model.note = " caffè "
        let category = try #require(model.categoryID)

        #expect(await model.save())

        let items = try await firstValue(database.operations.observeRecent(limit: 5))
        let operation = try #require(items.first?.operation)
        #expect(items.count == 1)
        #expect(operation.amount == 1250)
        #expect(operation.kind == .expense)
        #expect(operation.categoryID == category)
        #expect(operation.date == Day(year: 2026, month: 10, day: 30))
        #expect(operation.note == "caffè")
    }

    @Test func editLoadsAndUpdatesExistingOperation() async throws {
        let creating = await makeModel(.new(kind: .income))
        fill(creating, amount: "1000")
        creating.note = "stipendio"
        #expect(await creating.save())
        let original = try #require(try await firstValue(database.operations.observeRecent(limit: 1)).first?.operation)

        let model = await makeModel(.edit(original.id))
        #expect(model.isEditing)
        #expect(model.kind == .income)
        #expect(AmountInput.minorUnits(from: model.amountText) == 100000)
        #expect(model.categoryID == original.categoryID)
        #expect(model.note == "stipendio")
        #expect(!model.hasChanges)
        #expect(model.canSave)

        model.amountText = "1100"
        #expect(model.hasChanges)
        #expect(await model.save())

        let updated = try #require(try await database.operations.operation(original.id))
        #expect(updated.amount == 110000)
        #expect(updated.createdAt == original.createdAt)
        let items = try await firstValue(database.operations.observeRecent(limit: 5))
        #expect(items.count == 1, "La modifica non crea una nuova operazione")
    }

    @Test func editKeepsArchivedCategorySelectable() async throws {
        let creating = await makeModel(.new(kind: .expense))
        fill(creating)
        let category = try #require(creating.categoryID)
        #expect(await creating.save())
        let operation = try #require(try await firstValue(database.operations.observeRecent(limit: 1)).first?.operation)
        #expect(try await database.categories.remove(category) == .archived)

        let editing = await makeModel(.edit(operation.id))
        #expect(editing.visibleCategories.contains { $0.id == category })
        #expect(editing.canSave)

        let new = await makeModel(.new(kind: .expense))
        #expect(!new.visibleCategories.contains { $0.id == category })
        #expect(new.categoryID == nil, "Una categoria archiviata non viene proposta")
    }

    @Test func missingOperationFailsToLoad() async {
        let model = await makeModel(.edit(OperationID()))
        #expect(model.loadState == .failed)
        #expect(!model.canSave)
        #expect(await model.save() == false)
    }

    // MARK: Modifiche

    @Test func detectsChangesAndRevertsToClean() async throws {
        let model = await makeModel(.new(kind: nil))
        model.amountText = "5"
        #expect(model.hasChanges)
        model.amountText = ""
        #expect(!model.hasChanges)

        model.date = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        #expect(model.hasChanges)
        model.date = today
        #expect(!model.hasChanges)

        // Stesso giorno, ora diversa: la data dell'operazione non cambia.
        model.date = today.addingTimeInterval(3600)
        #expect(!model.hasChanges)
    }
}
