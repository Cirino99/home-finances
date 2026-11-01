import Foundation
import Testing
@testable import Core

struct AmountInputTests {
    @Test(arguments: [
        ("12,50", 1250), ("12.50", 1250), ("12,5", 1250), ("12", 1200), ("0,01", 1), ("0", 0), (" 7 ", 700),
    ] as [(String, Int64)])
    func parsesValidText(text: String, expected: Int64) {
        #expect(AmountInput.minorUnits(from: text) == expected)
    }

    @Test(arguments: ["", " ", "abc", "12,", ",5", "1.234", "1,234", "1.000,50", "12,345", "-5", "1e3", "١٢"])
    func rejectsInvalidText(text: String) {
        #expect(AmountInput.minorUnits(from: text) == nil)
    }

    @Test func formatsWithoutGroupingAndWithLocaleSeparator() {
        #expect(AmountInput.text(minorUnits: 123450, locale: Locale(identifier: "it_IT")) == "1234,50")
        #expect(AmountInput.text(minorUnits: 123450, locale: Locale(identifier: "en_US")) == "1234.50")
    }

    @Test func formattedTextParsesBack() {
        let text = AmountInput.text(minorUnits: 4520, locale: Locale(identifier: "it_IT"))
        #expect(AmountInput.minorUnits(from: text) == 4520)
    }
}

@MainActor
struct AppRouterTests {
    @Test func opensEditorFromAnyPoint() {
        let router = AppRouter()
        router.newOperation(kind: .income)
        #expect(router.editor == .new(kind: .income))

        let id = OperationID()
        router.editor = .edit(id)
        #expect(router.editor == .edit(id))
    }

    @Test func showAllOperationsGoesToHistoryRoot() throws {
        let router = AppRouter()
        router.historyPath = [.year(2026)]
        router.showAllOperations()
        #expect(router.selectedTab == .history)
        #expect(router.historyPath.isEmpty)
    }

    @Test func lockClosesEditorAndKeepsPosition() {
        let router = AppRouter()
        router.selectedTab = .history
        router.historyPath = [.year(2026)]
        router.newOperation()

        router.dismissPresentations()

        #expect(router.editor == nil)
        #expect(router.selectedTab == .history)
        #expect(router.historyPath == [.year(2026)])
    }
}
