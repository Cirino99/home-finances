import Core
import SwiftUI

/// Riga di un mese o di un anno: titolo, entrate, uscite e saldo (§ 8.3).
public struct PeriodRow: View {
    private let title: String
    private let totals: PeriodTotals
    private let currency: String

    public init(title: String, totals: PeriodTotals, currency: String) {
        self.title = title
        self.totals = totals
        self.currency = currency
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(MoneyFormat.string(minorUnits: totals.balance, currency: currency, signed: true))
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(totals.balance < 0 ? Color.expense : Color.primary)
                    .accessibilityLabel("Saldo \(MoneyFormat.string(minorUnits: totals.balance, currency: currency, signed: true))")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    amount("arrow.down.circle", totals.income, color: .income, label: "Entrate")
                    amount("arrow.up.circle", totals.expense, color: .expense, label: "Uscite")
                }
                VStack(alignment: .leading, spacing: 4) {
                    amount("arrow.down.circle", totals.income, color: .income, label: "Entrate")
                    amount("arrow.up.circle", totals.expense, color: .expense, label: "Uscite")
                }
            }
            .font(.footnote)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func amount(_ symbol: String, _ value: Int64, color: Color, label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityLabel(label)
            Text(MoneyFormat.string(minorUnits: value, currency: currency))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
