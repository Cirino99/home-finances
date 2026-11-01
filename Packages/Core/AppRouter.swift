import Foundation
import Observation

public enum AppTab: String, CaseIterable, Sendable {
    case home
    case history
}

/// Cosa deve mostrare l'editor (§ 7.3). `nil` nel router significa editor chiuso.
public enum EditorRequest: Hashable, Identifiable, Sendable {
    /// `kind` è già impostato dall'aggiunta rapida, altrimenti `nil`.
    case new(kind: OperationKind?)
    case edit(OperationID)

    public var id: Self { self }
}

/// Segmenti dello Storico (§ 8.3).
public enum HistorySegment: String, CaseIterable, Sendable {
    case operations
    case months
    case years
}

public enum HistoryRoute: Hashable, Sendable {
    case operation(OperationID)
    case month(YearMonth)
    case year(Int)
}

/// Azioni sui dati chieste dalle Impostazioni o dal menu del Mac (§ 10). Le esegue la radice dell'app:
/// un pannello non si può aprire mentre si sta chiudendo lo sheet delle Impostazioni.
public enum TransferRequest: Equatable, Sendable {
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
    public var homePath: [OperationID] = []
    public var historySegment: HistorySegment = .operations
    public var historyPath: [HistoryRoute] = []
    public var isSettingsPresented = false
    public var transferRequest: TransferRequest?
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

    /// "Vedi tutte" in Home (§ 7.3).
    public func showAllOperations() {
        selectedTab = .history
        historySegment = .operations
        historyPath = []
    }

    /// Al blocco si chiude ciò che è aperto sopra il contenuto (§ 5.4). Tab e percorso restano,
    /// così dopo lo sblocco l'utente ritrova la stessa posizione.
    public func dismissPresentations() {
        editor = nil
        isSettingsPresented = false
        transferRequest = nil
    }

    /// Dopo un import i dati sono altri: niente di ciò che era aperto ha più senso (§ 10.4).
    public func resetNavigation() {
        dismissPresentations()
        selectedTab = .home
        homePath = []
        historyPath = []
    }
}
