import Core
import DesignSystem
import SwiftUI

/// Elenco dello Storico: con selezione nella colonna di una split view, senza in uno stack.
typealias HistoryList<Content: View> = SelectableList<HistoryRoute, Content>

/// Riga che apre `route` nello Storico. Su Mac il dettaglio non ha uno stack: la route si aggiunge al percorso.
struct HistoryRouteRow<Content: View>: View {
    let route: HistoryRoute
    let isSelectable: Bool
    @ViewBuilder let content: Content
    @Environment(AppRouter.self) private var router

    var body: some View {
        RouteRow(route: route, isSelectable: isSelectable, open: { router.historyPath.append($0) }) {
            content
        }
    }
}

#if os(iOS)
/// Campo di ricerca sotto il picker dei segmenti.
struct HistorySearchField: View {
    @Binding var text: String
    let isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Nota, categoria o conto", text: $text)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused(isFocused)
            if !text.isEmpty {
                Button("Cancella ricerca", systemImage: "xmark.circle.fill") {
                    text = ""
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

/// Barra di ricerca propria, per "Operazioni del mese": nell'elenco completo la ricerca sta nella stessa
/// barra del selettore dei segmenti, in `HistoryRoot`.
private struct OwnSearchBar: ViewModifier {
    let isEnabled: Bool
    @Binding var text: String
    let isFocused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if isEnabled {
            content.safeAreaBar(edge: .top, spacing: 0) {
                HistorySearchField(text: $text, isFocused: isFocused)
            }
        } else {
            content
        }
    }
}
#endif

/// Segmento Operazioni e vista "Operazioni del mese" (§ 8.3): operazioni e trasferimenti.
struct OperationListView: View {
    let selection: Binding<HistoryRoute?>?
    @State private var model: OperationListModel
    @State private var pendingDeletion: MovementID?
    /// Testo cercato nella barra di `HistoryRoot` su iPhone e iPad; `nil` se la ricerca è di questa vista.
    let searchText: Binding<String>?
    @FocusState private var isSearchFocused: Bool
    @Environment(AppRouter.self) private var router

    init(
        month: YearMonth?,
        repositories: HistoryRepositories,
        selection: Binding<HistoryRoute?>? = nil,
        searchText: Binding<String>? = nil
    ) {
        self.selection = selection
        self.searchText = searchText
        _model = State(initialValue: OperationListModel(month: month, repositories: repositories))
    }

    var body: some View {
        @Bindable var model = model
        HistoryList(selection: selection) {
            if model.month != nil, let currency = model.currency {
                Section {
                    PeriodSummary(totals: model.totals, currency: currency)
                }
            }
            if let account = model.filteredAccount {
                Section {
                    AccountFilterLabel(name: account.name) { model.accountID = nil }
                }
            }
            ForEach(model.sections) { section in
                Section(DayFormat.sectionTitle(section.day, today: today)) {
                    ForEach(section.items) { item in
                        row(item)
                    }
                }
            }
            if model.hasMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .onAppear { model.loadMore() }
            }
        }
        .overlay { emptyState }
        #if os(macOS)
        .searchable(text: $model.searchText, prompt: "Nota, categoria o conto")
        .searchFocused($isSearchFocused)
        #else
        // Non `.searchable`: starebbe sopra il picker dei segmenti e lo sposterebbe a ogni cambio di segmento.
        .modifier(OwnSearchBar(isEnabled: searchText == nil, text: $model.searchText, isFocused: $isSearchFocused))
        .onChange(of: searchText?.wrappedValue, initial: true) { _, text in
            if let text {
                model.searchText = text
            }
        }
        .scrollDismissesKeyboard(.interactively)
        #endif
        .onAppear {
            focusSearchIfPending()
            applyPendingAccountFilter()
        }
        .onChange(of: router.isSearchPending) { focusSearchIfPending() }
        .onChange(of: router.pendingHistoryAccountFilter) { applyPendingAccountFilter() }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                filterMenu
            }
        }
        .alert(
            "Eliminazione non riuscita",
            isPresented: Binding(get: { model.deleteFailed }, set: { _ in model.clearDeleteFailure() })
        ) {
            Button("OK", role: .cancel) {}
        }
        #if os(macOS)
        .onDeleteCommand {
            switch selection?.wrappedValue {
            case .operation(let id): pendingDeletion = .operation(id)
            case .transfer(let id): pendingDeletion = .transfer(id)
            default: break
            }
        }
        #endif
        .task(id: model.query) { await model.observeItems() }
        .task { await model.observeTotals() }
        .task { await model.observeCategories() }
        .task { await model.observeAccounts() }
    }

    private var today: Day {
        Day(containing: Date())
    }

    /// Solo dall'elenco completo, non da "Operazioni del mese". Se la ricerca sta nella barra di
    /// `HistoryRoot`, il focus lo dà lei.
    private func focusSearchIfPending() {
        guard router.isSearchPending, model.month == nil, searchText == nil else { return }
        router.isSearchPending = false
        isSearchFocused = true
    }

    /// "Vedi tutte nello Storico" da un conto (§ 8.7). Come la ricerca, vale per l'elenco completo.
    private func applyPendingAccountFilter() {
        guard model.month == nil, let account = router.pendingHistoryAccountFilter else { return }
        router.pendingHistoryAccountFilter = nil
        // Anche il campo della barra comune: altrimenti mostrerebbe un testo che non filtra più nulla.
        searchText?.wrappedValue = ""
        model.show(account: account)
    }

    /// La conferma di una riga: su iOS 26 il dialogo è un popover che punta alla vista a cui è attaccato.
    private func isConfirmingDeletion(of id: MovementID) -> Binding<Bool> {
        Binding(
            get: { pendingDeletion == id },
            set: { isPresented in
                if !isPresented, pendingDeletion == id {
                    pendingDeletion = nil
                }
            }
        )
    }

    private func deletionTitle(for id: MovementID) -> LocalizedStringKey {
        if case .transfer = id {
            "Eliminare questo trasferimento?"
        } else {
            "Eliminare questa operazione?"
        }
    }

    private func row(_ item: MovementListItem) -> some View {
        HistoryRouteRow(route: HistoryRoute(item.id), isSelectable: selection != nil) {
            MovementRow(item: item, today: today, account: model.accountID)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Senza ruolo distruttivo: la riga deve restare finché non arriva la conferma.
            Button("Elimina", systemImage: "trash") { pendingDeletion = item.id }
                .tint(.red)
        }
        .swipeActions(edge: .leading) {
            Button("Modifica", systemImage: "pencil") { edit(item.id) }
                .tint(.accentColor)
        }
        .contextMenu {
            Button("Modifica", systemImage: "pencil") { edit(item.id) }
            Button("Elimina", systemImage: "trash", role: .destructive) { pendingDeletion = item.id }
        }
        // Sulla riga e non sull'elenco: il popover della conferma deve indicare il movimento da eliminare.
        .confirmationDialog(
            deletionTitle(for: item.id),
            isPresented: isConfirmingDeletion(of: item.id),
            titleVisibility: .visible
        ) {
            Button("Elimina", role: .destructive) { delete(item.id) }
        }
    }

    private func edit(_ id: MovementID) {
        router.editor = EditorRequest(editing: id)
    }

    private func delete(_ id: MovementID) {
        // Un dettaglio aperto su questo movimento non avrebbe più nulla da mostrare.
        let route = HistoryRoute(id)
        router.historyPath.removeAll { $0 == route }
        Task { await model.delete(id) }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.loadFailed, model.items.isEmpty {
            ContentUnavailableView(
                "Dati non disponibili",
                systemImage: "exclamationmark.triangle",
                description: Text("Non è stato possibile caricare i movimenti.")
            )
        } else if model.hasLoaded, model.items.isEmpty {
            if model.isSearching {
                ContentUnavailableView.search(text: model.searchText)
            } else if model.isFiltering {
                ContentUnavailableView {
                    Label("Nessun risultato", systemImage: "line.3.horizontal.decrease.circle")
                } actions: {
                    Button("Togli i filtri") { model.clearFilters() }
                }
            } else {
                ContentUnavailableView {
                    Label("Nessuna operazione", systemImage: "tray")
                } actions: {
                    Button("Aggiungi la prima") { router.newOperation() }
                }
            }
        }
    }

    private var filterMenu: some View {
        @Bindable var model = model
        return Menu {
            Picker("Tipo", selection: $model.kind) {
                Text("Tutte").tag(MovementKind?.none)
                Text("Entrate").tag(MovementKind?.some(.income))
                Text("Uscite").tag(MovementKind?.some(.expense))
                Text("Trasferimenti").tag(MovementKind?.some(.transfer))
            }
            // I trasferimenti non hanno categoria (§ 8.3).
            if model.kind != .transfer {
                Picker("Categoria", selection: $model.categoryID) {
                    Text("Tutte").tag(CategoryID?.none)
                    ForEach(model.visibleCategories) { category in
                        Text(category.name).tag(CategoryID?.some(category.id))
                    }
                }
            }
            if model.showsAccountFilter {
                Picker("Conto", selection: $model.accountID) {
                    Text("Tutti").tag(AccountID?.none)
                    ForEach(model.accounts) { account in
                        Text(account.name).tag(AccountID?.some(account.id))
                    }
                }
            }
            if model.isFiltering {
                Divider()
                Button("Togli i filtri") { model.clearFilters() }
            }
        } label: {
            Label(
                "Filtri",
                systemImage: model.isFiltering
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
    }
}

/// Filtro per conto attivo, visibile anche fuori dal menu (§ 8.3). La × lo toglie.
private struct AccountFilterLabel: View {
    let name: String
    let onClear: () -> Void

    var body: some View {
        HStack {
            Label {
                Text("Conto: \(name)")
            } icon: {
                Image(systemName: "building.columns")
            }
            .foregroundStyle(.secondary)
            Spacer()
            Button("Togli il filtro per conto", systemImage: "xmark.circle.fill", action: onClear)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}
