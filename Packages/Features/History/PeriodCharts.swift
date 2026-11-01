import Charts
import Core
import DesignSystem
import SwiftUI

/// `Double` solo per disegnare: Swift Charts non traccia `Decimal`, e i testi usano sempre `MoneyFormat`.
private func plotted(_ minorUnits: Int64) -> Double {
    Double(minorUnits) / Double(MinorUnits.perUnit)
}

/// Entrate e uscite affiancate per mese (§ 8.3). Il tipo si legge anche dalla posizione,
/// sempre entrate a sinistra e uscite a destra, non solo dal colore.
struct MonthsChart: View {
    let months: [MonthTotals]
    let currency: String
    @State private var selectedLabel: String?

    var body: some View {
        Chart {
            ForEach(months, id: \.month) { month in
                BarMark(
                    x: .value("Mese", label(month)),
                    y: .value("Importo", plotted(month.totals.income)),
                    width: .ratio(0.7)
                )
                .position(by: .value("Tipo", "Entrate"))
                .foregroundStyle(by: .value("Tipo", "Entrate"))
                .cornerRadius(3)
                .accessibilityLabel("\(DayFormat.monthTitle(month.month)), entrate")
                .accessibilityValue(MoneyFormat.string(minorUnits: month.totals.income, currency: currency))

                BarMark(
                    x: .value("Mese", label(month)),
                    y: .value("Importo", plotted(month.totals.expense)),
                    width: .ratio(0.7)
                )
                .position(by: .value("Tipo", "Uscite"))
                .foregroundStyle(by: .value("Tipo", "Uscite"))
                .cornerRadius(3)
                .accessibilityLabel("\(DayFormat.monthTitle(month.month)), uscite")
                .accessibilityValue(MoneyFormat.string(minorUnits: month.totals.expense, currency: currency))
            }

            if let selected {
                RuleMark(x: .value("Mese", label(selected)))
                    .foregroundStyle(.secondary.opacity(0.3))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        tooltip(selected)
                    }
            }
        }
        .chartForegroundStyleScale(["Entrate": Color.income, "Uscite": Color.expense])
        .chartXSelection(value: $selectedLabel)
        .chartLegend(position: .bottom)
        .frame(height: 220)
        .padding(.vertical, 8)
    }

    private var selected: MonthTotals? {
        months.first { label($0) == selectedLabel }
    }

    private func label(_ month: MonthTotals) -> String {
        DayFormat.shortMonth(month.month)
    }

    private func tooltip(_ month: MonthTotals) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(DayFormat.monthTitle(month.month))
                .font(.caption.bold())
            Text("Entrate \(MoneyFormat.string(minorUnits: month.totals.income, currency: currency))")
            Text("Uscite \(MoneyFormat.string(minorUnits: month.totals.expense, currency: currency))")
        }
        .font(.caption)
        .monospacedDigit()
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Saldo per anno (§ 8.3). Il segno si legge dal lato della linea di base, non solo dal colore.
struct YearsChart: View {
    let years: [YearTotals]
    let currency: String
    @State private var selectedLabel: String?

    var body: some View {
        Chart {
            ForEach(years, id: \.year) { year in
                BarMark(
                    x: .value("Anno", String(year.year)),
                    y: .value("Saldo", plotted(year.totals.balance)),
                    width: .ratio(0.5)
                )
                .foregroundStyle(year.totals.balance < 0 ? Color.expense : Color.income)
                .cornerRadius(3)
                .accessibilityLabel("\(String(year.year)), saldo")
                .accessibilityValue(MoneyFormat.string(minorUnits: year.totals.balance, currency: currency, signed: true))
            }

            RuleMark(y: .value("Zero", 0.0))
                .foregroundStyle(.secondary)

            if let selected {
                RuleMark(x: .value("Anno", String(selected.year)))
                    .foregroundStyle(.secondary.opacity(0.3))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        Text(MoneyFormat.string(minorUnits: selected.totals.balance, currency: currency, signed: true))
                            .font(.caption)
                            .monospacedDigit()
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
            }
        }
        .chartXSelection(value: $selectedLabel)
        .frame(height: 200)
        .padding(.vertical, 8)
    }

    private var selected: YearTotals? {
        years.first { String($0.year) == selectedLabel }
    }
}
