import Core
import DesignSystem
import SwiftUI

/// Elenco con selezione nella colonna di una split view, senza selezione in uno stack.
struct HistoryList<Content: View>: View {
    let selection: Binding<HistoryRoute?>?
    @ViewBuilder let content: Content

    var body: some View {
        if let selection {
            List(selection: selection) { content }
                #if os(macOS)
                // Con lo stile predefinito, su Mac le righe di questi elenchi risultano tagliate.
                .listStyle(.sidebar)
                #endif
                .environment(\.defaultMinListRowHeight, 52)
        } else {
            List { content }
                #if os(macOS)
                .listStyle(.sidebar)
                #endif
                .environment(\.defaultMinListRowHeight, 52)
        }
    }
}

/// Riga che apre `route`: nella colonna con selezione basta il tag. Altrove, su iPhone e iPad è un
/// link dello stack; su Mac il dettaglio non ha uno stack, quindi aggiunge `route` al percorso.
struct HistoryRouteRow<Content: View>: View {
    let route: HistoryRoute
    let isSelectable: Bool
    @ViewBuilder let content: Content
    @Environment(AppRouter.self) private var router

    var body: some View {
        if isSelectable {
            content.tag(route)
        } else {
            #if os(macOS)
            Button {
                router.historyPath.append(route)
            } label: {
                HStack {
                    content
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #else
            NavigationLink(value: route) { content }
            #endif
        }
    }
}

#if os(iOS)
/// Campo di ricerca sotto il picker dei segmenti.
private struct HistorySearchField: View {
    @Binding var text: String
    let isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Nota o categoria", text: $text)
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
#endif

/// Segmento Operazioni e vista "Operazioni del mese" (§ 8.3).
struct OperationListView: View {
    let selection: Binding<HistoryRoute?>?
    @State private var model: OperationListModel
    @State private var pendingDeletion: OperationID?
    @FocusState private var isSearchFocused: Bool
    @Environment(AppRouter.self) private var router

    init(month: YearMonth?, repositories: HistoryRepositories, selection: Binding<HistoryRoute?>? = nil) {
        self.selection = selection
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
        .searchable(text: $model.searchText, prompt: "Nota o categoria")
        .searchFocused($isSearchFocused)
        #else
        // Non `.searchable`: starebbe sopra il picker dei segmenti e lo sposterebbe a ogni cambio di segmento.
        .safeAreaBar(edge: .top, spacing: 0) {
            HistorySearchField(text: $model.searchText, isFocused: $isSearchFocused)
        }
        .scrollDismissesKeyboard(.interactively)
        #endif
        .onAppear(perform: focusSearchIfPending)
        .onChange(of: router.isSearchPending) { focusSearchIfPending() }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                filterMenu
            }
        }
        .confirmationDialog(
            "Eliminare questa operazione?",
            isPresented: isConfirmingDeletion,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { id in
            Button("Elimina", role: .destructive) { delete(id) }
        }
        .alert(
            "Eliminazione non riuscita",
            isPresented: Binding(get: { model.deleteFailed }, set: { _ in model.clearDeleteFailure() })
        ) {
            Button("OK", role: .cancel) {}
        }
        #if os(macOS)
        .onDeleteCommand {
            if case .operation(let id) = selection?.wrappedValue {
                pendingDeletion = id
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

    /// Solo dall'elenco completo, non da "Operazioni del mese".
    private func focusSearchIfPending() {
        guard router.isSearchPending, model.month == nil else { return }
        router.isSearchPending = false
        isSearchFocused = true
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletion = nil
                }
            }
        )
    }

    private func row(_ item: OperationListItem) -> some View {
        HistoryRouteRow(route: .operation(item.id), isSelectable: selection != nil) {
            OperationRow(item: item, today: today)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Senza ruolo distruttivo: la riga deve restare finché non arriva la conferma.
            Button("Elimina", systemImage: "trash") { pendingDeletion = item.id }
                .tint(.red)
        }
        .swipeActions(edge: .leading) {
            Button("Modifica", systemImage: "pencil") { router.editor = .edit(item.id) }
                .tint(.accentColor)
        }
        .contextMenu {
            Button("Modifica", systemImage: "pencil") { router.editor = .edit(item.id) }
            Button("Elimina", systemImage: "trash", role: .destructive) { pendingDeletion = item.id }
        }
    }

    private func delete(_ id: OperationID) {
        // Un dettaglio aperto su questa operazione non avrebbe più nulla da mostrare.
        router.historyPath.removeAll { $0 == .operation(id) }
        Task { await model.delete(id) }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.loadFailed, model.items.isEmpty {
            ContentUnavailableView(
                "Dati non disponibili",
                systemImage: "exclamationmark.triangle",
                description: Text("Non è stato possibile caricare le operazioni.")
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
                Text("Tutte").tag(OperationKind?.none)
                Text("Entrate").tag(OperationKind?.some(.income))
                Text("Uscite").tag(OperationKind?.some(.expense))
            }
            Picker("Categoria", selection: $model.categoryID) {
                Text("Tutte").tag(CategoryID?.none)
                ForEach(model.visibleCategories) { category in
                    Text(category.name).tag(CategoryID?.some(category.id))
                }
            }
            if model.accounts.count > 1 {
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
