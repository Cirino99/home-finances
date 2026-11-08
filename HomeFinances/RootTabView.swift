import AccountsFeature
import AppSecurity
import Core
import DesignSystem
import HistoryFeature
import HomeFeature
import LockFeature
import OperationEditorFeature
import Persistence
import SettingsFeature
import SwiftUI

/// Navigazione principale (§ 7): i tab e gli editor, presentati una sola volta da qui.
struct RootTabView: View {
    let database: AppDatabase
    let store: DatabaseStore
    let appLock: AppLock
    @Bindable var router: AppRouter
    @SceneStorage("selectedTab") private var storedTab = AppTab.home
    @SceneStorage("historySegment") private var storedSegment = HistorySegment.operations
    @State private var savedCount = 0

    var body: some View {
        TabView(selection: $router.selectedTab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack(path: $router.homePath) {
                    HomeView(
                        operations: database.operations,
                        transfers: database.transfers,
                        movements: database.movements,
                        accounts: database.accounts
                    )
                    .toolbar {
                        #if os(iOS)
                        // Su Mac le Impostazioni hanno una propria finestra, con ⌘, (§ 7.4).
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Impostazioni", systemImage: "gearshape") {
                                router.isSettingsPresented = true
                            }
                        }
                        #endif
                        newOperationButton
                    }
                }
            }
            Tab("Storico", systemImage: "list.bullet.rectangle", value: AppTab.history) {
                // Gestisce da sé stack e split view, a seconda dello spazio disponibile.
                HistoryView(
                    operations: database.operations,
                    transfers: database.transfers,
                    movements: database.movements,
                    categories: database.categories,
                    accounts: database.accounts
                )
            }
            Tab("Conti", systemImage: "building.columns", value: AppTab.accounts) {
                // Come lo Storico, gestisce da sé stack e colonne.
                AccountsView(
                    operations: database.operations,
                    transfers: database.transfers,
                    movements: database.movements
                )
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .environment(router)
        .sensoryFeedback(.success, trigger: savedCount)
        .sheet(item: $router.editor) { request in
            editor(for: request)
                .presentationSizing(.form)
                // L'overlay della radice non copre gli sheet (§ 9).
                .privacyCover(appLock.isPrivacyCovered)
        }
        // "Gestisci conti" dal tab Conti: la stessa schermata delle Impostazioni (§ 8.7).
        .sheet(isPresented: $router.isAccountManagementPresented) {
            NavigationStack {
                AccountsCatalogView(
                    repository: database.accounts,
                    transfers: database.transfers,
                    movements: database.movements
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fine") { router.isAccountManagementPresented = false }
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 480)
            #endif
            // Lo sheet è presentato da qui: non eredita l'ambiente impostato sul contenuto.
            .environment(router)
            .privacyCover(appLock.isPrivacyCovered)
        }
        .modifier(DataTransferPresenter(database: database, store: store, appLock: appLock, router: router))
        .onAppear {
            router.selectedTab = storedTab
            router.historySegment = storedSegment
        }
        .onChange(of: router.selectedTab) { _, tab in storedTab = tab }
        .onChange(of: router.historySegment) { _, segment in storedSegment = segment }
    }

    /// Un solo sheet per entrambi gli editor (§ 7.3): la richiesta dice quale mostrare.
    @ViewBuilder
    private func editor(for request: EditorRequest) -> some View {
        // I modelli si costruiscono a ogni valutazione, ma `@State` tiene il primo: l'init si limita
        // a salvare i repository, e la lettura dei dati parte da `load()` nella vista.
        switch request {
        case .newTransfer(let account):
            TransferEditorView(
                model: TransferEditorModel(from: account, transfers: database.transfers, movements: database.movements),
                onSaved: { savedCount += 1 }
            )
        case .editTransfer(let id):
            TransferEditorView(
                model: TransferEditorModel(transferID: id, transfers: database.transfers, movements: database.movements),
                onSaved: { savedCount += 1 }
            )
        case .new, .edit:
            OperationEditorView(
                model: OperationEditorModel(
                    request: request,
                    operations: database.operations,
                    categories: database.categories,
                    accounts: database.accounts
                ),
                onSaved: { savedCount += 1 }
            )
        }
    }

    /// Azione, non sezione: sta nella toolbar e non nella tab bar (§ 7.2, Opzione A).
    private var newOperationButton: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Nuova operazione", systemImage: "plus") { router.newOperation() }
        }
    }
}
