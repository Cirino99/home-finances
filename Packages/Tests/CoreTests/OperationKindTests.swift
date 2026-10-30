import Testing
@testable import Core

struct OperationKindTests {
    @Test func rawValuesMatchSchema() {
        #expect(OperationKind.income.rawValue == "income")
        #expect(OperationKind.expense.rawValue == "expense")
    }
}
