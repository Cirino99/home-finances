import Foundation
import Testing
@testable import Core

struct MoneyTests {
    @Test(arguments: [
        ("12.34", 1234), ("0.01", 1), ("100", 10000), ("0.1", 10), ("-5.5", -550), ("0", 0),
    ] as [(String, Int64)])
    func convertsDecimalToMinorUnits(text: String, expected: Int64) throws {
        let value = try #require(Decimal(string: text, locale: Locale(identifier: "en_US")))
        #expect(try MinorUnits.from(value) == expected)
        #expect(MinorUnits.decimal(expected) == value)
    }

    @Test(arguments: ["0.001", "12.345", "1.999"])
    func rejectsMoreThanTwoDecimals(text: String) throws {
        let value = try #require(Decimal(string: text, locale: Locale(identifier: "en_US")))
        #expect(throws: MoneyError.tooManyDecimals) {
            try MinorUnits.from(value)
        }
    }

    @Test func rejectsValuesOutOfRange() throws {
        let value = try #require(Decimal(string: "1000000000000000000", locale: Locale(identifier: "en_US")))
        #expect(throws: MoneyError.outOfRange) {
            try MinorUnits.from(value)
        }
    }

    /// Con `Double` questo valore perderebbe un centesimo.
    @Test func keepsExactValuesThatDoubleWouldRound() throws {
        let value = try #require(Decimal(string: "1.15", locale: Locale(identifier: "en_US")))
        #expect(try MinorUnits.from(value) == 115)
    }

    @Test func formatsWithLocale() {
        let italian = Locale(identifier: "it_IT")
        let text = MoneyFormat.string(minorUnits: 123456, currency: "EUR", locale: italian)
        #expect(text.contains("1234,56") || text.contains("1.234,56"))
        #expect(text.contains("€"))

        let american = MoneyFormat.string(minorUnits: 123456, currency: "USD", locale: Locale(identifier: "en_US"))
        #expect(american == "$1,234.56")
    }

    @Test func signIsAlwaysExplicitForOperations() {
        let locale = Locale(identifier: "en_US")
        #expect(MoneyFormat.string(amount: 500, kind: .income, currency: "USD", locale: locale) == "+$5.00")
        #expect(MoneyFormat.string(amount: 500, kind: .expense, currency: "USD", locale: locale) == "-$5.00")
    }
}
