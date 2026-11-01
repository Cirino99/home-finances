import AppSecurity
import Core
import HistoryFeature
import HomeFeature
import LockFeature
import OperationEditorFeature
import Persistence
import SwiftUI

/// Navigazione principale (§ 7): due tab e l'editor, presentato una sola volta da qui.
struct RootTabView: View {
    let database: AppDatabase
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
                        .toolbar { newOperationButton }
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
            OperationEditorView(
                model: OperationEditorModel(
                    request: request,
                    operations: database.operations,
                    categories: database.categories,
                    accounts: database.accounts
                ),
                onSaved: { savedCount += 1 }
            )
            .presentationSizing(.form)
            // L'overlay della radice non copre gli sheet (§ 9).
            .privacyCover(appLock.isPrivacyCovered)
        }
        .onAppear {
            router.selectedTab = storedTab
            router.historySegment = storedSegment
        }
        .onChange(of: router.selectedTab) { _, tab in storedTab = tab }
        .onChange(of: router.historySegment) { _, segment in storedSegment = segment }
    }

    /// Azione, non sezione: sta nella toolbar e non nella tab bar (§ 7.2, Opzione A).
    private var newOperationButton: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Nuova operazione", systemImage: "plus") { router.newOperation() }
        }
    }
}
