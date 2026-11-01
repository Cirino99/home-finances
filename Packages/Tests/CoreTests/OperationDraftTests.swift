import Foundation
import Testing
@testable import Core

struct OperationDraftTests {
    func makeDraft(amount: Int64 = 100, note: String? = nil) throws -> OperationDraft {
        OperationDraft(
            kind: .expense,
            amount: amount,
            date: try #require(Day(string: "2026-10-30")),
            accountID: AccountID(),
            categoryID: CategoryID(),
            note: note
        )
    }

    @Test(arguments: [0, -1] as [Int64])
    func amountMustBePositive(amount: Int64) throws {
        let draft = try makeDraft(amount: amount)
        #expect(throws: OperationDraftError.amountNotPositive) {
            try draft.validate()
        }
    }

    @Test func noteHasMaximumLength() throws {
        try makeDraft(note: String(repeating: "a", count: 200)).validate()

        let tooLong = try makeDraft(note: String(repeating: "a", count: 201))
        #expect(throws: OperationDraftError.noteTooLong) {
            try tooLong.validate()
        }
    }

    @Test func noteIsNormalized() throws {
        #expect(try makeDraft(note: "  caffè \n").normalizedNote == "caffè")
        #expect(try makeDraft(note: "   ").normalizedNote == nil)
        #expect(try makeDraft(note: nil).normalizedNote == nil)
    }

    @Test func totalsComputeBalance() {
        #expect(PeriodTotals(income: 1000, expense: 1500).balance == -500)
    }

    @Test func defaultDataMatchesSpecification() {
        let names = { (kind: OperationKind) in
            DefaultData.categories.filter { $0.kind == kind }.map(\.name)
        }
        #expect(names(.expense) == ["Casa", "Spesa", "Trasporti", "Ristoranti", "Salute", "Svago", "Abbonamenti", "Altro"])
        #expect(names(.income) == ["Stipendio", "Rimborsi", "Regali", "Altro"])
    }
}
