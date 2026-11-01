import Core
import Foundation
import Observation

/// Repository usati dallo Storico.
struct HistoryRepositories {
    let operations: any OperationRepository
    let categories: any CategoryRepository
    let accounts: any AccountRepository
}

/// Operazioni raggruppate per giorno, con ricerca, filtri e pagine (§ 8.3).
/// Con `month` è la vista "Operazioni del mese".
@MainActor
@Observable
final class OperationListModel {
    struct DaySection: Identifiable, Equatable {
        let day: Day
        let items: [OperationListItem]

        var id: Day { day }
    }

    let month: YearMonth?

    var searchText = "" {
        didSet { pages = 1 }
    }
    var kind: OperationKind? {
        didSet {
            pages = 1
            // Una categoria dell'altro tipo escluderebbe tutto.
            if let categoryID, !visibleCategories.contains(where: { $0.id == categoryID }) {
                self.categoryID = nil
            }
        }
    }
    var categoryID: CategoryID? {
        didSet { pages = 1 }
    }
    var accountID: AccountID? {
        didSet { pages = 1 }
    }

    private(set) var items: [OperationListItem] = []
    private(set) var totals = PeriodTotals()
    private(set) var categories: [OperationCategory] = []
    private(set) var accounts: [Account] = []
    private(set) var hasLoaded = false
    private(set) var loadFailed = false
    private(set) var deleteFailed = false
    private var pages = 1

    private let repositories: HistoryRepositories
    private let pageSize: Int

    init(month: YearMonth?, repositories: HistoryRepositories, pageSize: Int = OperationQuery.defaultPageSize) {
        self.month = month
        self.repositories = repositories
        self.pageSize = pageSize
    }

    /// La vista riavvia la lettura quando cambia: ricerca, filtri o numero di pagine.
    var query: OperationQuery {
        OperationQuery(
            month: month,
            searchText: searchText,
            kind: kind,
            categoryID: categoryID,
            accountID: accountID,
            limit: pageSize * pages
        )
    }

    var sections: [DaySection] {
        var sections: [DaySection] = []
        var current: [OperationListItem] = []
        for item in items {
            if let last = current.last, last.operation.date != item.operation.date {
                sections.append(DaySection(day: last.operation.date, items: current))
                current = []
            }
            current.append(item)
        }
        if let last = current.last {
            sections.append(DaySection(day: last.operation.date, items: current))
        }
        return sections
    }

    /// Una pagina piena può averne un'altra dopo; una incompleta è l'ultima.
    var hasMore: Bool {
        items.count >= query.limit
    }

    var isFiltering: Bool {
        kind != nil || categoryID != nil || accountID != nil
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var visibleCategories: [OperationCategory] {
        categories.filter { kind == nil || $0.kind == kind }
    }

    var currency: String? {
        accounts.first?.currency
    }

    func loadMore() {
        if hasMore {
            pages += 1
        }
    }

    func clearFilters() {
        kind = nil
        categoryID = nil
        accountID = nil
    }

    func delete(_ id: OperationID) async {
        do {
            try await repositories.operations.delete(id)
        } catch {
            deleteFailed = true
        }
    }

    func clearDeleteFailure() {
        deleteFailed = false
    }

    // MARK: Letture

    func observeItems() async {
        do {
            for try await value in repositories.operations.observeItems(query) {
                items = value
                hasLoaded = true
            }
        } catch {
            loadFailed = true
        }
    }

    /// Riepilogo in testa a "Operazioni del mese".
    func observeTotals() async {
        guard let month else { return }
        do {
            for try await value in repositories.operations.observeTotals(for: month) {
                totals = value
            }
        } catch {
            loadFailed = true
        }
    }

    func observeCategories() async {
        do {
            for try await value in repositories.categories.observeCategories(includingArchived: true) {
                categories = value
            }
        } catch {
            loadFailed = true
        }
    }

    func observeAccounts() async {
        do {
            for try await value in repositories.accounts.observeAccounts(includingArchived: true) {
                accounts = value
            }
        } catch {
            loadFailed = true
        }
    }
}

/// Mesi con almeno un'operazione, tutti o di un solo anno (§ 8.3).
@MainActor
@Observable
final class MonthsModel {
    let year: Int?
    private(set) var rows: [MonthTotals] = []
    private(set) var currency: String?
    private(set) var hasLoaded = false
    private(set) var loadFailed = false

    private let repositories: HistoryRepositories
    private let currentMonth: YearMonth

    init(year: Int?, repositories: HistoryRepositories, now: Date = Date(), calendar: Calendar = .current) {
        self.year = year
        self.repositories = repositories
        currentMonth = YearMonth(containing: now, calendar: calendar)
    }

    /// Dodici mesi consecutivi, dal più vecchio, compresi quelli senza operazioni:
    /// gli ultimi 12, oppure gennaio-dicembre se è indicato un anno.
    var chartMonths: [MonthTotals] {
        var months: [YearMonth] = []
        if let year {
            months = (1...12).compactMap { YearMonth(year: year, month: $0) }
        } else {
            var month: YearMonth? = currentMonth
            while let current = month, months.count < 12 {
                months.insert(current, at: 0)
                month = current.previous
            }
        }
        return months.map { month in
            rows.first { $0.month == month } ?? MonthTotals(month: month, totals: PeriodTotals())
        }
    }

    func observeRows() async {
        do {
            for try await value in repositories.operations.observeMonthlyTotals(year: year) {
                rows = value
                hasLoaded = true
            }
        } catch {
            loadFailed = true
        }
    }

    func observeCurrency() async {
        do {
            for try await value in repositories.accounts.observeAccounts(includingArchived: true) {
                currency = value.first?.currency
            }
        } catch {
            loadFailed = true
        }
    }
}

/// Anni con almeno un'operazione (§ 8.3).
@MainActor
@Observable
final class YearsModel {
    private(set) var rows: [YearTotals] = []
    private(set) var currency: String?
    private(set) var hasLoaded = false
    private(set) var loadFailed = false

    private let repositories: HistoryRepositories

    init(repositories: HistoryRepositories) {
        self.repositories = repositories
    }

    /// Dal più vecchio, per leggere il grafico da sinistra a destra.
    var chartYears: [YearTotals] {
        rows.reversed()
    }

    func observeRows() async {
        do {
            for try await value in repositories.operations.observeYearlyTotals() {
                rows = value
                hasLoaded = true
            }
        } catch {
            loadFailed = true
        }
    }

    func observeCurrency() async {
        do {
            for try await value in repositories.accounts.observeAccounts(includingArchived: true) {
                currency = value.first?.currency
            }
        } catch {
            loadFailed = true
        }
    }
}
