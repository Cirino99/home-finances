import Core
import Foundation
import Observation

/// Repository usati dal tab Conti.
struct AccountsRepositories {
    let operations: any OperationRepository
    let transfers: any TransferRepository
    let movements: any MovementRepository
}

/// Saldo totale e saldi dei conti (§ 8.7). Si aggiornano da soli dopo ogni movimento.
@MainActor
@Observable
final class AccountsModel {
    private(set) var balances: [AccountBalance] = []
    private(set) var hasLoaded = false
    private(set) var loadFailed = false

    private let movements: any MovementRepository

    init(movements: any MovementRepository) {
        self.movements = movements
    }

    /// Conti attivi, nell'ordine scelto in Gestisci conti.
    var activeBalances: [AccountBalance] {
        balances.filter { !$0.account.isArchived }
    }

    /// Conti archiviati su cui resta qualcosa: i soldi ci sono ancora (§ 6.4).
    var archivedBalances: [AccountBalance] {
        balances.filter { $0.account.isArchived && $0.balance != 0 }
    }

    /// Tutti i conti, archiviati compresi.
    var total: Int64 {
        AccountBalance.total(of: balances)
    }

    var currency: String? {
        balances.first?.account.currency
    }

    /// Servono almeno due conti attivi (§ 8.7).
    var canTransfer: Bool {
        activeBalances.count >= 2
    }

    func observeBalances() async {
        do {
            for try await value in movements.observeBalances() {
                balances = value
                hasLoaded = true
            }
        } catch {
            loadFailed = true
        }
    }
}

/// Dettaglio di un conto: saldo e ultime movimentazioni (§ 8.7).
@MainActor
@Observable
final class AccountDetailModel {
    static let recentLimit = 5

    let accountID: AccountID
    private(set) var balance: AccountBalance?
    private(set) var recent: [MovementListItem] = []
    private(set) var hasLoadedBalance = false
    private(set) var hasLoadedRecent = false
    private(set) var loadFailed = false
    private var activeAccountCount = 0

    private let movements: any MovementRepository

    init(accountID: AccountID, movements: any MovementRepository) {
        self.accountID = accountID
        self.movements = movements
    }

    /// Il conto non esiste più, per esempio è stato cancellato mentre era aperto.
    var isMissing: Bool {
        hasLoadedBalance && balance == nil
    }

    /// Da un conto archiviato non si trasferisce: l'editor propone solo conti attivi (§ 8.8).
    var showsTransferButton: Bool {
        balance.map { !$0.account.isArchived } ?? false
    }

    var canTransfer: Bool {
        activeAccountCount >= 2
    }

    func observeBalance() async {
        do {
            for try await value in movements.observeBalances() {
                balance = value.first { $0.account.id == accountID }
                activeAccountCount = value.count(where: { !$0.account.isArchived })
                hasLoadedBalance = true
            }
        } catch {
            loadFailed = true
        }
    }

    func observeRecent() async {
        do {
            for try await value in movements.observeRecentMovements(limit: Self.recentLimit, account: accountID) {
                recent = value
                hasLoadedRecent = true
            }
        } catch {
            loadFailed = true
        }
    }
}
