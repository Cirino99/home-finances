import Core
import DesignSystem
import OperationEditorFeature
import SwiftUI

/// Tab Conti (§ 8.7). `router.accountsPath` è l'unica fonte del percorso, come nello Storico (§ 7.3):
/// su iPhone è lo stack, su iPad e Mac il primo elemento è il conto selezionato.
public struct AccountsView: View {
    private let repositories: AccountsRepositories
    @Environment(AppRouter.self) private var router
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #else
    @AppStorage("accountsListWidth") private var listWidth = 340.0
    #endif

    public init(
        operations: any OperationRepository,
        transfers: any TransferRepository,
        movements: any MovementRepository
    ) {
        repositories = AccountsRepositories(operations: operations, transfers: transfers, movements: movements)
    }

    public var body: some View {
        #if os(macOS)
        // Come nello Storico: colonne affiancate, perché una split view annidata nella sidebar sposta il dettaglio.
        HStack(spacing: 0) {
            NavigationStack {
                AccountsListView(repositories: repositories, selection: selection)
            }
            .frame(width: listWidth)
            ColumnResizeHandle(width: $listWidth, range: 260...560)
            detail
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        }
        #else
        @Bindable var router = router
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                AccountsListView(repositories: repositories, selection: selection)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 460)
            } detail: {
                detail
            }
        } else {
            NavigationStack(path: $router.accountsPath) {
                AccountsListView(repositories: repositories, selection: nil)
                    .navigationDestination(for: AccountsRoute.self, destination: destination)
            }
        }
        #endif
    }

    private var selection: Binding<AccountsRoute?> {
        Binding(
            get: { router.accountsPath.first },
            set: { route in router.accountsPath = route.map { [$0] } ?? [] }
        )
    }

    #if os(macOS)
    /// Mostra direttamente l'ultimo elemento del percorso, come il dettaglio dello Storico.
    @ViewBuilder
    private var detail: some View {
        if let route = router.accountsPath.last {
            destination(route)
                .id(route)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if router.accountsPath.count > 1 {
                        HStack(spacing: 8) {
                            Button("Indietro", systemImage: "chevron.left") {
                                router.accountsPath.removeLast()
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .keyboardShortcut("[", modifiers: .command)
                            Text("Dettaglio")
                                .font(.headline)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.bar)
                    }
                }
        } else {
            ContentUnavailableView("Seleziona un conto", systemImage: "building.columns")
        }
    }
    #else
    /// Ciò che si è aperto dentro il dettaglio, oltre al conto selezionato.
    private var detailPath: Binding<[AccountsRoute]> {
        Binding(
            get: { Array(router.accountsPath.dropFirst()) },
            set: { path in
                if let first = router.accountsPath.first {
                    router.accountsPath = [first] + path
                }
            }
        )
    }

    @ViewBuilder
    private var detail: some View {
        if let route = router.accountsPath.first {
            NavigationStack(path: detailPath) {
                destination(route)
                    .navigationDestination(for: AccountsRoute.self, destination: destination)
            }
            .id(route)
        } else {
            ContentUnavailableView("Seleziona un conto", systemImage: "building.columns")
        }
    }
    #endif

    @ViewBuilder
    private func destination(_ route: AccountsRoute) -> some View {
        switch route {
        case .account(let id):
            AccountDetailView(accountID: id, repositories: repositories)
        case .operation(let id):
            OperationDetailView(id: id, operations: repositories.operations) {
                router.accountsPath.removeAll { $0 == route }
            }
        case .transfer(let id):
            TransferDetailView(id: id, transfers: repositories.transfers) {
                router.accountsPath.removeAll { $0 == route }
            }
        }
    }
}

/// Riga che apre `route`, come `HistoryRouteRow` nello Storico: nella colonna con selezione basta il tag;
/// altrove è un link dello stack, o su Mac aggiunge `route` al percorso.
struct AccountsRouteRow<Content: View>: View {
    let route: AccountsRoute
    let isSelectable: Bool
    @ViewBuilder let content: Content
    @Environment(AppRouter.self) private var router

    var body: some View {
        if isSelectable {
            content.tag(route)
        } else {
            #if os(macOS)
            Button {
                router.accountsPath.append(route)
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

/// Elenco con selezione nella colonna di una split view, senza selezione in uno stack.
struct AccountsList<Content: View>: View {
    let selection: Binding<AccountsRoute?>?
    @ViewBuilder let content: Content

    var body: some View {
        if let selection {
            List(selection: selection) { content }
                #if os(macOS)
                .listStyle(.sidebar)
                #endif
        } else {
            List { content }
                #if os(macOS)
                .listStyle(.sidebar)
                #endif
        }
    }
}

// MARK: Elenco dei conti

/// Saldo totale, conti attivi e conti archiviati con un saldo (§ 8.7).
struct AccountsListView: View {
    let selection: Binding<AccountsRoute?>?
    @State private var model: AccountsModel
    @State private var showsArchived = false
    @State private var isShowingTooFewAccounts = false
    @Environment(AppRouter.self) private var router

    init(repositories: AccountsRepositories, selection: Binding<AccountsRoute?>?) {
        self.selection = selection
        _model = State(initialValue: AccountsModel(movements: repositories.movements))
    }

    var body: some View {
        AccountsList(selection: selection) {
            if let currency = model.currency {
                Section {
                    BalanceHeader(title: "Saldo totale", amount: model.total, currency: currency)
                }
            }
            if !model.activeBalances.isEmpty {
                Section("Conti") {
                    ForEach(model.activeBalances) { balance in
                        row(balance)
                    }
                }
            }
            if !model.archivedBalances.isEmpty {
                Section("Archiviati", isExpanded: $showsArchived) {
                    ForEach(model.archivedBalances) { balance in
                        row(balance)
                    }
                }
            }
        }
        .overlay {
            if model.loadFailed, model.balances.isEmpty {
                ContentUnavailableView(
                    "Dati non disponibili",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Non è stato possibile caricare i conti.")
                )
            }
        }
        .navigationTitle("Conti")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Trasferisci", systemImage: "arrow.left.arrow.right") {
                    if model.canTransfer {
                        router.newTransfer()
                    } else {
                        isShowingTooFewAccounts = true
                    }
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Gestisci conti", systemImage: "slider.horizontal.3") {
                    router.isAccountManagementPresented = true
                }
            }
        }
        .tooFewAccountsAlert(isPresented: $isShowingTooFewAccounts)
        .task { await model.observeBalances() }
    }

    private func row(_ balance: AccountBalance) -> some View {
        AccountsRouteRow(route: .account(balance.account.id), isSelectable: selection != nil) {
            AccountBalanceRow(balance: balance)
        }
    }
}

// MARK: Dettaglio del conto

/// Saldo del conto, ultime 5 movimentazioni e collegamento allo Storico filtrato (§ 8.7).
struct AccountDetailView: View {
    @State private var model: AccountDetailModel
    @State private var isShowingTooFewAccounts = false
    @Environment(AppRouter.self) private var router

    init(accountID: AccountID, repositories: AccountsRepositories) {
        _model = State(initialValue: AccountDetailModel(accountID: accountID, movements: repositories.movements))
    }

    var body: some View {
        Group {
            if let balance = model.balance {
                details(balance)
            } else if model.isMissing {
                ContentUnavailableView("Conto non disponibile", systemImage: "exclamationmark.triangle")
            } else if model.loadFailed {
                ContentUnavailableView(
                    "Dati non disponibili",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Non è stato possibile caricare il conto.")
                )
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model.balance?.account.name ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if model.showsTransferButton {
                ToolbarItem(placement: .primaryAction) {
                    Button("Trasferisci", systemImage: "arrow.left.arrow.right") {
                        if model.canTransfer {
                            router.newTransfer(from: model.accountID)
                        } else {
                            isShowingTooFewAccounts = true
                        }
                    }
                }
            }
        }
        .tooFewAccountsAlert(isPresented: $isShowingTooFewAccounts)
        .task { await model.observeBalance() }
        .task { await model.observeRecent() }
    }

    private func details(_ balance: AccountBalance) -> some View {
        List {
            Section {
                BalanceHeader(title: "Saldo", amount: balance.balance, currency: balance.account.currency)
                if balance.account.isArchived {
                    Label("Conto archiviato", systemImage: "archivebox")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Ultime movimentazioni") {
                if model.hasLoadedRecent, model.recent.isEmpty {
                    Text("Nessun movimento su questo conto.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.recent) { item in
                    AccountsRouteRow(route: route(of: item.id), isSelectable: false) {
                        MovementRow(item: item, today: today, account: model.accountID)
                    }
                }
            }
            Section {
                Button {
                    router.showHistory(account: model.accountID)
                } label: {
                    Text("Vedi tutte nello Storico")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var today: Day {
        Day(containing: Date())
    }

    private func route(of id: MovementID) -> AccountsRoute {
        switch id {
        case .operation(let id): .operation(id)
        case .transfer(let id): .transfer(id)
        }
    }
}

// MARK: Componenti

/// Saldo in evidenza, con il segno sempre esplicito: negativo in rosso (§ 6.4).
struct BalanceHeader: View {
    let title: LocalizedStringKey
    let amount: Int64
    let currency: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(MoneyFormat.string(minorUnits: amount, currency: currency, signed: true))
                .font(.largeTitle.bold())
                .monospacedDigit()
                .foregroundStyle(amount < 0 ? Color.expense : Color.primary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Nome e saldo di un conto nell'elenco.
struct AccountBalanceRow: View {
    let balance: AccountBalance

    var body: some View {
        HStack {
            Text(balance.account.name)
                .lineLimit(2)
            Spacer()
            Text(MoneyFormat.string(minorUnits: balance.balance, currency: balance.account.currency, signed: true))
                .monospacedDigit()
                .foregroundStyle(balance.balance < 0 ? Color.expense : Color.primary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// "Trasferisci" con meno di due conti attivi (§ 8.7): si propone di aggiungerne uno.
    func tooFewAccountsAlert(isPresented: Binding<Bool>) -> some View {
        modifier(TooFewAccountsAlert(isPresented: isPresented))
    }
}

private struct TooFewAccountsAlert: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(AppRouter.self) private var router

    func body(content: Content) -> some View {
        content.alert("Per trasferire servono almeno due conti", isPresented: $isPresented) {
            Button("Aggiungi un conto") { router.isAccountManagementPresented = true }
            Button("Annulla", role: .cancel) {}
        }
    }
}
