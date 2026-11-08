import Core
import OperationEditorFeature
import SwiftUI

/// Storico (§ 8.3). `router.historyPath` è l'unica fonte del percorso: su iPhone è lo stack
/// (§ 7.3), su iPad e Mac il primo elemento è la selezione e il resto lo stack del dettaglio.
public struct HistoryView: View {
    private let repositories: HistoryRepositories
    @Environment(AppRouter.self) private var router
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #else
    @AppStorage("historyListWidth") private var listWidth = 360.0
    #endif

    public init(
        operations: any OperationRepository,
        transfers: any TransferRepository,
        movements: any MovementRepository,
        categories: any CategoryRepository,
        accounts: any AccountRepository
    ) {
        repositories = HistoryRepositories(
            operations: operations,
            transfers: transfers,
            movements: movements,
            categories: categories,
            accounts: accounts
        )
    }

    public var body: some View {
        #if os(macOS)
        // Niente `NavigationSplitView`: annidata nella sidebar dell'app, sposta il dettaglio
        // verso destra lasciando un vuoto a sinistra. Affiancate così, le colonne restano al loro posto.
        HStack(spacing: 0) {
            NavigationStack {
                HistoryRoot(repositories: repositories, selection: selection)
            }
            .frame(width: listWidth)
            ColumnResizeHandle(width: $listWidth, range: 280...640)
            detail
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        }
        #else
        @Bindable var router = router
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                HistoryRoot(repositories: repositories, selection: selection)
                    .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 480)
            } detail: {
                detail
            }
        } else {
            NavigationStack(path: $router.historyPath) {
                HistoryRoot(repositories: repositories, selection: nil)
                    .navigationDestination(for: HistoryRoute.self, destination: destination)
            }
        }
        #endif
    }

    private var selection: Binding<HistoryRoute?> {
        Binding(
            get: { router.historyPath.first },
            set: { route in router.historyPath = route.map { [$0] } ?? [] }
        )
    }

    #if os(macOS)
    /// Mostra direttamente l'ultimo elemento del percorso, senza uno stack di navigazione:
    /// con due stack affiancati, aprire un elemento nel dettaglio faceva sparire la lista.
    @ViewBuilder
    private var detail: some View {
        if let route = router.historyPath.last {
            destination(route)
                .id(route)
                .safeAreaInset(edge: .top, spacing: 0) {
                    detailHeader(route)
                }
        } else {
            ContentUnavailableView("Seleziona un elemento", systemImage: "list.bullet.rectangle")
        }
    }

    private func detailHeader(_ route: HistoryRoute) -> some View {
        HStack(spacing: 8) {
            if router.historyPath.count > 1 {
                Button("Indietro", systemImage: "chevron.left") {
                    router.historyPath.removeLast()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut("[", modifiers: .command)
            }
            Text(title(of: route))
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func title(of route: HistoryRoute) -> String {
        switch route {
        case .operation, .transfer: "Dettaglio"
        case .month(let month): DayFormat.monthTitle(month)
        case .year(let year): String(year)
        }
    }
    #else
    /// Ciò che si è aperto dentro il dettaglio, oltre alla selezione.
    private var detailPath: Binding<[HistoryRoute]> {
        Binding(
            get: { Array(router.historyPath.dropFirst()) },
            set: { path in
                if let first = router.historyPath.first {
                    router.historyPath = [first] + path
                }
            }
        )
    }

    @ViewBuilder
    private var detail: some View {
        if let route = router.historyPath.first {
            NavigationStack(path: detailPath) {
                destination(route)
                    .navigationDestination(for: HistoryRoute.self, destination: destination)
            }
            .id(route)
        } else {
            ContentUnavailableView("Seleziona un elemento", systemImage: "list.bullet.rectangle")
        }
    }
    #endif

    @ViewBuilder
    private func destination(_ route: HistoryRoute) -> some View {
        switch route {
        case .operation(let id):
            OperationDetailView(id: id, operations: repositories.operations) {
                router.historyPath.removeAll { $0 == route }
            }
        case .transfer(let id):
            TransferDetailView(id: id, transfers: repositories.transfers) {
                router.historyPath.removeAll { $0 == route }
            }
        case .month(let month):
            OperationListView(month: month, repositories: repositories)
                .navigationTitle(DayFormat.monthTitle(month))
        case .year(let year):
            MonthsListView(year: year, repositories: repositories)
                .navigationTitle(String(year))
        }
    }
}

#if os(macOS)
/// Linea tra lista e dettaglio, da trascinare per cambiare la larghezza della lista.
/// La larghezza scelta resta salvata tra un avvio e l'altro.
private struct ColumnResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var widthAtDragStart: Double?

    var body: some View {
        Divider()
            .overlay {
                // Più larga della linea, per afferrarla senza dover essere precisi.
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        // Coordinate globali: la linea si sposta con la colonna durante il trascinamento.
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                let start = widthAtDragStart ?? width
                                widthAtDragStart = start
                                width = min(max(start + value.translation.width, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in
                                widthAtDragStart = nil
                            }
                    )
            }
    }
}
#endif

/// Picker a segmenti ed elenco del segmento scelto.
private struct HistoryRoot: View {
    let repositories: HistoryRepositories
    let selection: Binding<HistoryRoute?>?
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        Group {
            switch router.historySegment {
            case .operations:
                OperationListView(month: nil, repositories: repositories, selection: selection)
            case .months:
                MonthsListView(year: nil, repositories: repositories, selection: selection)
            case .years:
                YearsListView(repositories: repositories, selection: selection)
            }
        }
        #if os(iOS)
        // Barra di sistema: il contenuto che scorre sotto viene sfocato, invece di leggersi attraverso i controlli.
        .safeAreaBar(edge: .top) {
            segmentPicker($router.historySegment)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        #else
        .safeAreaInset(edge: .top) {
            segmentPicker($router.historySegment)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        #endif
        .navigationTitle("Storico")
        .toolbar {
            // Azione, non sezione: sta nella toolbar e non nella tab bar (§ 7.2, Opzione A).
            ToolbarItem(placement: .primaryAction) {
                Button("Nuova operazione", systemImage: "plus") { router.newOperation() }
            }
        }
        // Le righe di un altro segmento non possono restare selezionate.
        .onChange(of: router.historySegment) {
            router.historyPath = []
        }
    }

    private func segmentPicker(_ selection: Binding<HistorySegment>) -> some View {
        Picker("Vista", selection: selection) {
            Text("Operazioni").tag(HistorySegment.operations)
            Text("Mesi").tag(HistorySegment.months)
            Text("Anni").tag(HistorySegment.years)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
