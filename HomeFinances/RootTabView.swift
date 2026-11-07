import AppSecurity
import Core
import HistoryFeature
import HomeFeature
import LockFeature
import OperationEditorFeature
import Persistence
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
                    HomeView(operations: database.operations, accounts: database.accounts)
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
                    categories: database.categories,
                    accounts: database.accounts
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
        if let model = TransferEditorModel(
            request: request,
            transfers: database.transfers,
            movements: database.movements
        ) {
            TransferEditorView(model: model, onSaved: { savedCount += 1 })
        } else {
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
