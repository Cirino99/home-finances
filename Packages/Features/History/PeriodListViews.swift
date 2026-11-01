import Core
import DesignSystem
import SwiftUI

/// Segmento Mesi e vista "Mesi dell'anno" (§ 8.3).
struct MonthsListView: View {
    let selection: Binding<HistoryRoute?>?
    @State private var model: MonthsModel

    init(year: Int?, repositories: HistoryRepositories, selection: Binding<HistoryRoute?>? = nil) {
        self.selection = selection
        _model = State(initialValue: MonthsModel(year: year, repositories: repositories))
    }

    var body: some View {
        HistoryList(selection: selection) {
            if let currency = model.currency, !model.rows.isEmpty {
                Section {
                    MonthsChart(months: model.chartMonths, currency: currency)
                }
                Section {
                    ForEach(model.rows, id: \.month) { row in
                        HistoryRouteRow(route: .month(row.month), isSelectable: selection != nil) {
                            PeriodRow(
                                title: DayFormat.monthTitle(row.month),
                                totals: row.totals,
                                currency: currency
                            )
                        }
                    }
                }
            }
        }
        .overlay {
            if model.loadFailed, model.rows.isEmpty {
                PeriodLoadFailureView()
            } else if model.hasLoaded, model.rows.isEmpty {
                ContentUnavailableView("Nessuna operazione", systemImage: "tray")
            }
        }
        .task { await model.observeRows() }
        .task { await model.observeCurrency() }
    }
}

/// Segmento Anni (§ 8.3).
struct YearsListView: View {
    let selection: Binding<HistoryRoute?>?
    @State private var model: YearsModel

    init(repositories: HistoryRepositories, selection: Binding<HistoryRoute?>? = nil) {
        self.selection = selection
        _model = State(initialValue: YearsModel(repositories: repositories))
    }

    var body: some View {
        HistoryList(selection: selection) {
            if let currency = model.currency, !model.rows.isEmpty {
                Section {
                    YearsChart(years: model.chartYears, currency: currency)
                }
                Section {
                    ForEach(model.rows, id: \.year) { row in
                        HistoryRouteRow(route: .year(row.year), isSelectable: selection != nil) {
                            PeriodRow(title: String(row.year), totals: row.totals, currency: currency)
                        }
                    }
                }
            }
        }
        .overlay {
            if model.loadFailed, model.rows.isEmpty {
                PeriodLoadFailureView()
            } else if model.hasLoaded, model.rows.isEmpty {
                ContentUnavailableView("Nessuna operazione", systemImage: "tray")
            }
        }
        .task { await model.observeRows() }
        .task { await model.observeCurrency() }
    }
}

private struct PeriodLoadFailureView: View {
    var body: some View {
        ContentUnavailableView(
            "Dati non disponibili",
            systemImage: "exclamationmark.triangle",
            description: Text("Non è stato possibile caricare i totali.")
        )
    }
}
