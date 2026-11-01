import Core
import Foundation
import Observation

/// Stato della Home (§ 8.2). Le letture restano attive finché la vista è presente:
/// dopo ogni inserimento, modifica o eliminazione la schermata si aggiorna da sola.
@MainActor
@Observable
public final class HomeModel {
    /// Le ultime operazioni sono le più recenti in assoluto, non quelle del mese selezionato.
    public static let recentLimit = 3

    public private(set) var today: Day
    public private(set) var month: YearMonth
    public private(set) var totals = PeriodTotals()
    public private(set) var recent: [OperationListItem] = []
    public private(set) var currency: String?
    public private(set) var hasLoadedRecent = false
    public private(set) var loadFailed = false

    private let operations: any OperationRepository
    private let accounts: any AccountRepository
    private let now: () -> Date
    private let calendar: Calendar

    public init(
        operations: any OperationRepository,
        accounts: any AccountRepository,
        now: @escaping () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.operations = operations
        self.accounts = accounts
        self.now = now
        self.calendar = calendar
        let today = Day(containing: now(), calendar: calendar)
        self.today = today
        month = today.yearMonth
    }

    // MARK: Selettore del mese

    public var currentMonth: YearMonth {
        today.yearMonth
    }

    public var isCurrentMonth: Bool {
        month == currentMonth
    }

    /// Niente mesi futuri (§ 8.2).
    public var canGoToNextMonth: Bool {
        month < currentMonth
    }

    public var canGoToPreviousMonth: Bool {
        month.previous != nil
    }

    public func goToPreviousMonth() {
        if let previous = month.previous {
            month = previous
        }
    }

    public func goToNextMonth() {
        if canGoToNextMonth, let next = month.next {
            month = next
        }
    }

    public func goToCurrentMonth() {
        month = currentMonth
    }

    /// Da chiamare al ritorno in primo piano: la data può essere cambiata. Chi stava
    /// guardando il mese corrente resta sul mese corrente.
    public func refreshToday() {
        let wasCurrentMonth = isCurrentMonth
        today = Day(containing: now(), calendar: calendar)
        if wasCurrentMonth {
            month = currentMonth
        }
    }

    // MARK: Letture

    /// Totali del mese selezionato. La vista la riavvia quando cambia `month`.
    public func observeTotals() async {
        do {
            for try await value in operations.observeTotals(for: month) {
                totals = value
            }
        } catch {
            loadFailed = true
        }
    }

    public func observeRecent() async {
        do {
            for try await value in operations.observeRecent(limit: Self.recentLimit) {
                recent = value
                hasLoadedRecent = true
            }
        } catch {
            loadFailed = true
        }
    }

    /// Valuta dell'app, unica in v1 (§ 6.1): quella del primo conto.
    public func observeCurrency() async {
        do {
            for try await value in accounts.observeAccounts(includingArchived: true) {
                currency = value.first?.currency
            }
        } catch {
            loadFailed = true
        }
    }
}
