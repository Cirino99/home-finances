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

public enum HistoryRoute: Hashable, Sendable {
    case operation(OperationID)
    case month(YearMonth)
    case year(Int)
}

/// Stato della navigazione. Ogni punto dell'app apre l'editor impostando `editor`:
/// lo sheet è presentato una sola volta, dalla radice (§ 7.3).
@MainActor
@Observable
public final class AppRouter {
    public var selectedTab: AppTab = .home
    public var editor: EditorRequest?
    public var historyPath: [HistoryRoute] = []

    public init() {}

    public func newOperation(kind: OperationKind? = nil) {
        editor = .new(kind: kind)
    }

    /// "Vedi tutte" in Home (§ 7.3).
    public func showAllOperations() {
        selectedTab = .history
        historyPath = []
    }

    /// Al blocco si chiude ciò che è aperto sopra il contenuto (§ 5.4). Tab e percorso restano,
    /// così dopo lo sblocco l'utente ritrova la stessa posizione.
    public func dismissPresentations() {
        editor = nil
    }
}
