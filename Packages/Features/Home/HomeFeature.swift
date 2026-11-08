import Core
import DesignSystem
import OperationEditorFeature
import SwiftUI

/// Home (§ 8.2): riepilogo del mese, aggiunta rapida e ultime operazioni.
public struct HomeView: View {
    private let operations: any OperationRepository
    private let transfers: any TransferRepository
    @State private var model: HomeModel
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    public init(
        operations: any OperationRepository,
        transfers: any TransferRepository,
        movements: any MovementRepository,
        accounts: any AccountRepository
    ) {
        self.operations = operations
        self.transfers = transfers
        _model = State(initialValue: HomeModel(operations: operations, movements: movements, accounts: accounts))
    }

    public var body: some View {
        List {
            Section {
                monthSelector
                if let currency = model.currency {
                    PeriodSummary(totals: model.totals, currency: currency)
                        .listRowSeparator(.hidden, edges: .top)
                }
            }
            Section {
                quickAdd
            }
            recentSection
        }
        #if os(iOS)
        .listSectionSpacing(.compact)
        #endif
        .navigationTitle("Home")
        .navigationDestination(for: HomeRoute.self) { route in
            switch route {
            case .operation(let id):
                OperationDetailView(id: id, operations: operations)
            case .transfer(let id):
                TransferDetailView(id: id, transfers: transfers)
            }
        }
        .task(id: model.month) { await model.observeTotals() }
        .task { await model.observeRecent() }
        .task { await model.observeCurrency() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.refreshToday()
            }
        }
    }

    private var monthSelector: some View {
        HStack {
            monthArrow("Mese precedente", systemImage: "chevron.left", action: model.goToPreviousMonth)
                .disabled(!model.canGoToPreviousMonth)
            Spacer()
            Button(action: model.goToCurrentMonth) {
                Text(DayFormat.monthTitle(model.month))
                    .font(.headline)
                    .foregroundStyle(Color.primary)
            }
            .accessibilityHint(model.isCurrentMonth ? "" : "Torna al mese corrente")
            Spacer()
            monthArrow("Mese successivo", systemImage: "chevron.right", action: model.goToNextMonth)
                .disabled(!model.canGoToNextMonth)
        }
        .buttonStyle(.borderless)
        .listRowSeparator(.hidden)
    }

    /// Area toccabile di 44 punti, come chiedono le HIG, anche se l'icona è piccola.
    private func monthArrow(
        _ title: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }

    private var quickAdd: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                quickAddButton("Entrata", kind: .income)
                quickAddButton("Uscita", kind: .expense)
            }
            VStack(spacing: 8) {
                quickAddButton("Entrata", kind: .income)
                quickAddButton("Uscita", kind: .expense)
            }
        }
        .buttonStyle(.glass)
        #if os(iOS)
        // Sfondo trasparente: i tasti si allineano ai bordi delle sezioni, senza margini propri.
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
        #endif
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func quickAddButton(_ title: LocalizedStringKey, kind: OperationKind) -> some View {
        Button {
            router.newOperation(kind: kind)
        } label: {
            Label {
                Text(title)
                    .foregroundStyle(Color.primary)
            } icon: {
                Image(systemName: "plus")
                    .foregroundStyle(kind.color)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if model.hasLoadedRecent {
            if model.recent.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Nessuna operazione", systemImage: "tray")
                    } actions: {
                        Button("Aggiungi la prima") { router.newOperation() }
                    }
                }
            } else {
                Section("Ultime operazioni") {
                    ForEach(model.recent) { item in
                        NavigationLink(value: route(of: item.id)) {
                            MovementRow(item: item, today: model.today)
                        }
                    }
                    Button {
                        router.showAllOperations()
                    } label: {
                        Text("Vedi tutte")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }
        } else if model.loadFailed {
            Section {
                Text("Non è stato possibile caricare i dati.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func route(of id: MovementID) -> HomeRoute {
        switch id {
        case .operation(let id): .operation(id)
        case .transfer(let id): .transfer(id)
        }
    }
}
