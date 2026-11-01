import Core
import SwiftUI

/// Entrate, uscite e saldo di un periodo (§ 8.2). Si usa dentro una sezione di `List` o `Form`.
public struct PeriodSummary: View {
    private let totals: PeriodTotals
    private let currency: String

    public init(totals: PeriodTotals, currency: String) {
        self.totals = totals
        self.currency = currency
    }

    public var body: some View {
        VStack(spacing: 12) {
            row(
                "Entrate",
                systemImage: "arrow.down.circle",
                amount: totals.income,
                color: .income
            )
            row(
                "Uscite",
                systemImage: "arrow.up.circle",
                amount: totals.expense,
                color: .expense
            )
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("Saldo")
                    .font(.headline)
                Spacer()
                Text(MoneyFormat.string(minorUnits: totals.balance, currency: currency, signed: true))
                    .font(.title2.bold())
                    .monospacedDigit()
                    .foregroundStyle(totals.balance < 0 ? Color.expense : Color.primary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.vertical, 4)
    }

    private func row(
        _ title: LocalizedStringKey,
        systemImage: String,
        amount: Int64,
        color: Color
    ) -> some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
            }
            Spacer()
            Text(MoneyFormat.string(minorUnits: amount, currency: currency))
                .monospacedDigit()
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
