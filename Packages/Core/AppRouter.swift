import Foundation
import Observation

/// Sezioni dell'app, nell'ordine dei tab: Home · Storico · Conti (§ 7.1).
public enum AppTab: String, CaseIterable, Sendable {
    case home
    case history
    case accounts
}

/// Cosa deve mostrare l'editor (§ 7.3). `nil` nel router significa editor chiuso.
public enum EditorRequest: Hashable, Identifiable, Sendable {
    /// `kind` è già impostato dall'aggiunta rapida, altrimenti `nil`.
    case new(kind: OperationKind?)
    case edit(OperationID)
    /// Nuovo trasferimento (§ 8.8); `from` è il conto da cui si è partiti, altrimenti `nil`.
    case newTransfer(from: AccountID?)
    case editTransfer(TransferID)

    public var id: Self { self }

    /// `true` per le richieste che aprono l'editor di trasferimento invece di quello di operazione.
    public var isTransfer: Bool {
        switch self {
        case .new, .edit: false
        case .newTransfer, .editTransfer: true
        }
    }
}

/// Segmenti dello Storico (§ 8.3).
public enum HistorySegment: String, CaseIterable, Sendable {
    case operations
    case months
    case years
}

public enum HistoryRoute: Hashable, Sendable {
    case operation(OperationID)
    case transfer(TransferID)
    case month(YearMonth)
    case year(Int)
}

/// Dettagli aperti dalla Home (§ 8.2): le ultime operazioni comprendono i trasferimenti.
public enum HomeRoute: Hashable, Sendable {
    case operation(OperationID)
    case transfer(TransferID)
}

/// Percorso del tab Conti (§ 8.7): un conto, e da lì un suo movimento.
public enum AccountsRoute: Hashable, Sendable {
    case account(AccountID)
    case operation(OperationID)
    case transfer(TransferID)
}

/// Azioni sui dati chieste dalle Impostazioni o dal menu del Mac (§ 10). Le esegue la radice dell'app:
/// un pannello non si può aprire mentre si sta chiudendo lo sheet delle Impostazioni.
public enum DataTransferRequest: Equatable, Sendable {
    case exportDatabase
    case importDatabase
    case exportCSV
    case undoImport
}

/// Stato della navigazione. Ogni punto dell'app apre l'editor impostando `editor`:
/// lo sheet è presentato una sola volta, dalla radice (§ 7.3).
@MainActor
@Observable
public final class AppRouter {
    public var selectedTab: AppTab = .home
    public var editor: EditorRequest?
    /// Dettagli aperti dalla Home (§ 8.2).
    public var homePath: [HomeRoute] = []
    public var historySegment: HistorySegment = .operations
    public var historyPath: [HistoryRoute] = []
    /// Filtro per conto chiesto da fuori dallo Storico, per esempio dal dettaglio di un conto (§ 7.3).
    /// L'elenco lo legge, lo applica come gli altri filtri e lo azzera.
    public var pendingHistoryAccountFilter: AccountID?
    /// Come `historyPath`: su iPad e Mac il primo elemento è il conto selezionato.
    public var accountsPath: [AccountsRoute] = []
    public var isSettingsPresented = false
    /// "Gestisci conti" dal tab Conti (§ 8.7): la stessa schermata delle Impostazioni.
    public var isAccountManagementPresented = false
    public var dataTransferRequest: DataTransferRequest?
    /// File `.homefinances` aperto dall'esterno: l'import parte solo dopo lo sblocco (§ 10.4).
    public var pendingImportURL: URL?
    /// Esito di un'azione sui dati, mostrato sopra tutto.
    public var transferMessage: String?
    /// ⌘F: il campo di ricerca prende il focus appena è sullo schermo.
    public var isSearchPending = false

    public init() {}

    /// La ricerca sta nel segmento Operazioni dello Storico (§ 8.3).
    public func requestSearch() {
        selectedTab = .history
        historySegment = .operations
        isSearchPending = true
    }

    public func newOperation(kind: OperationKind? = nil) {
        editor = .new(kind: kind)
    }

    /// "Trasferisci" (§ 7.2): `from` è il conto aperto, se c'è.
    public func newTransfer(from account: AccountID? = nil) {
        editor = .newTransfer(from: account)
    }

    /// "Vedi tutte" in Home (§ 7.3).
    public func showAllOperations() {
        selectedTab = .history
        historySegment = .operations
        historyPath = []
    }

    /// "Vedi tutte nello Storico" dal dettaglio di un conto (§ 8.7).
    public func showHistory(account: AccountID) {
        showAllOperations()
        pendingHistoryAccountFilter = account
    }

    /// Al blocco si chiude ciò che è aperto sopra il contenuto (§ 5.4). Tab e percorso restano,
    /// così dopo lo sblocco l'utente ritrova la stessa posizione.
    public func dismissPresentations() {
        editor = nil
        isSettingsPresented = false
        isAccountManagementPresented = false
        dataTransferRequest = nil
    }

    /// Dopo un import i dati sono altri: niente di ciò che era aperto ha più senso (§ 10.4).
    public func resetNavigation() {
        dismissPresentations()
        selectedTab = .home
        homePath = []
        historyPath = []
        accountsPath = []
        pendingHistoryAccountFilter = nil
    }
}
