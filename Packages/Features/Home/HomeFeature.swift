import Core
import DesignSystem
import OperationEditorFeature
import SwiftUI

/// Home (§ 8.2): riepilogo del mese, aggiunta rapida e ultime operazioni.
public struct HomeView: View {
    private let operations: any OperationRepository
    @State private var model: HomeModel
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    public init(operations: any OperationRepository, accounts: any AccountRepository) {
        self.operations = operations
        _model = State(initialValue: HomeModel(operations: operations, accounts: accounts))
    }

    public var body: some View {
        List {
            Section {
                monthSelector
                if let currency = model.currency {
                    PeriodSummary(totals: model.totals, currency: currency)
                }
            }
            Section {
                quickAdd
            }
            recentSection
        }
        .navigationTitle("Home")
        .navigationDestination(for: OperationID.self) { id in
            OperationDetailView(id: id, operations: operations)
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
            Button("Mese precedente", systemImage: "chevron.left", action: model.goToPreviousMonth)
                .labelStyle(.iconOnly)
                .disabled(!model.canGoToPreviousMonth)
            Spacer()
            Button(action: model.goToCurrentMonth) {
                Text(DayFormat.monthTitle(model.month))
                    .font(.headline)
                    .foregroundStyle(Color.primary)
            }
            .accessibilityHint(model.isCurrentMonth ? "" : "Torna al mese corrente")
            Spacer()
            Button("Mese successivo", systemImage: "chevron.right", action: model.goToNextMonth)
                .labelStyle(.iconOnly)
                .disabled(!model.canGoToNextMonth)
        }
        .buttonStyle(.borderless)
    }

    private var quickAdd: some View {
        HStack(spacing: 12) {
            quickAddButton("Entrata", kind: .income)
            quickAddButton("Uscita", kind: .expense)
        }
        .buttonStyle(.glass)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private func quickAddButton(_ title: LocalizedStringKey, kind: OperationKind) -> some View {
        Button {
            router.newOperation(kind: kind)
        } label: {
            Label(title, systemImage: "plus")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .tint(kind.color)
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
                        NavigationLink(value: item.id) {
                            OperationRow(item: item, today: model.today)
                        }
                    }
                    Button("Vedi tutte") { router.showAllOperations() }
                }
            }
        } else if model.loadFailed {
            Section {
                Text("Non è stato possibile caricare i dati.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
