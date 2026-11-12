import Core
import DesignSystem
import OperationEditorFeature
import SwiftUI

/// Tab Conti (§ 8.7). `router.accountsPath` è l'unica fonte del percorso, come nello Storico (§ 7.3):
/// su iPhone è lo stack, su iPad e Mac il primo elemento è il conto selezionato.
public struct AccountsView: View {
    private let repositories: AccountsRepositories
    @Environment(AppRouter.self) private var router

    public init(
        operations: any OperationRepository,
        transfers: any TransferRepository,
        movements: any MovementRepository
    ) {
        repositories = AccountsRepositories(operations: operations, transfers: transfers, movements: movements)
    }

    public var body: some View {
        @Bindable var router = router
        SplitNavigation(
            path: $router.accountsPath,
            listWidthKey: "accountsListWidth",
            defaultListWidth: 340,
            listWidthRange: 260...560,
            placeholder: "Seleziona un conto",
            placeholderSymbol: "building.columns",
            // Il dettaglio di un conto ha già il nome come titolo: la barra serve solo per tornare indietro.
            detailTitle: { route in
                if case .account = route { nil } else { String(localized: "Dettaglio") }
            }
        ) { selection in
            AccountsListView(repositories: repositories, selection: selection)
        } destination: { route in
            destination(route)
        }
    }

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

/// Riga che apre `route` nel tab Conti. Su Mac il dettaglio non ha uno stack: la route si aggiunge al percorso.
struct AccountsRouteRow<Content: View>: View {
    let route: AccountsRoute
    let isSelectable: Bool
    @ViewBuilder let content: Content
    @Environment(AppRouter.self) private var router

    var body: some View {
        RouteRow(route: route, isSelectable: isSelectable, open: { router.accountsPath.append($0) }) {
            content
        }
    }
}

/// Elenco del tab Conti: con selezione nella colonna di una split view, senza in uno stack.
typealias AccountsList<Content: View> = SelectableList<AccountsRoute, Content>

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
                // Non `Section(isExpanded:)`: su iOS si apre e chiude solo con lo stile `.sidebar`,
                // e con quello predefinito la sezione resterebbe chiusa per sempre.
                Section {
                    if showsArchived {
                        ForEach(model.archivedBalances) { balance in
                            row(balance)
                        }
                    }
                } header: {
                    Button {
                        withAnimation { showsArchived.toggle() }
                    } label: {
                        HStack {
                            Text("Archiviati")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(showsArchived ? 90 : 0))
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(showsArchived ? "Aperta" : "Chiusa")
                    .accessibilityHint("Mostra o nasconde i conti archiviati con un saldo")
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
        #if os(iOS)
        // Come lo Storico: titolo grande ma fisso nella barra, uguale in tutte le sezioni (§ 9).
        .toolbarTitleDisplayMode(.inlineLarge)
        #endif
        .toolbar {
            // Accanto a "Trasferisci": con `.secondaryAction` su Mac finirebbe al centro della toolbar.
            // Prima nel codice, quindi a sinistra, anche quando "Trasferisci" è quello del dettaglio.
            ToolbarItem(placement: .primaryAction) {
                Button("Gestisci conti", systemImage: "slider.horizontal.3") {
                    router.isAccountManagementPresented = true
                }
            }
            if !detailShowsTransferButton {
                ToolbarItem(placement: .primaryAction) {
                    Button("Trasferisci", systemImage: "arrow.left.arrow.right") {
                        if model.canTransfer {
                            router.newTransfer()
                        } else {
                            isShowingTooFewAccounts = true
                        }
                    }
                }
            }
        }
        .tooFewAccountsAlert(isPresented: $isShowingTooFewAccounts)
        .task { await model.observeBalances() }
    }

    /// Con elenco e dettaglio affiancati (iPad e Mac) le toolbar si vedono insieme, e su Mac sono
    /// una sola: se il dettaglio mostra un conto attivo, il suo "Trasferisci" basta e parte già da quel conto.
    private var detailShowsTransferButton: Bool {
        guard selection != nil, case .account(let id) = router.accountsPath.last else { return false }
        return model.activeBalances.contains { $0.account.id == id }
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
        // Mai vuoto, nemmeno durante il caricamento o se il conto non c'è più (HIG, VoiceOver).
        .navigationTitle(model.balance?.account.name ?? String(localized: "Conto"))
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
                    AccountsRouteRow(route: AccountsRoute(item.id), isSelectable: false) {
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Con le dimensioni di accessibilità nome e saldo non stanno su una riga: si impilano (§ 9).
        let isLarge = dynamicTypeSize.isAccessibilitySize
        let layout = isLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout())
        layout {
            Text(balance.account.name)
                .lineLimit(isLarge ? nil : 2)
            if !isLarge {
                Spacer()
            }
            Text(amountText)
                .monospacedDigit()
                .foregroundStyle(balance.balance < 0 ? Color.expense : Color.primary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(balance.account.name), saldo \(amountText)")
    }

    private var amountText: String {
        MoneyFormat.string(minorUnits: balance.balance, currency: balance.account.currency, signed: true)
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
