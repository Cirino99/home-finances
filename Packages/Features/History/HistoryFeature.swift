import Core
import DesignSystem
import OperationEditorFeature
import SwiftUI

/// Storico (§ 8.3). `router.historyPath` è l'unica fonte del percorso: su iPhone è lo stack
/// (§ 7.3), su iPad e Mac il primo elemento è la selezione e il resto lo stack del dettaglio.
public struct HistoryView: View {
    private let repositories: HistoryRepositories
    @Environment(AppRouter.self) private var router

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
        @Bindable var router = router
        SplitNavigation(
            path: $router.historyPath,
            listWidthKey: "historyListWidth",
            defaultListWidth: 360,
            listWidthRange: 280...640,
            placeholder: "Seleziona un elemento",
            placeholderSymbol: "list.bullet.rectangle",
            detailTitle: title(of:)
        ) { selection in
            HistoryRoot(repositories: repositories, selection: selection)
        } destination: { route in
            destination(route)
        }
    }

    private func title(of route: HistoryRoute) -> String? {
        switch route {
        case .operation, .transfer: String(localized: "Dettaglio")
        case .month(let month): DayFormat.monthTitle(month)
        case .year(let year): String(year)
        }
    }

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
