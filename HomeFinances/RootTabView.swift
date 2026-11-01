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
    @State private var savedCount = 0

    var body: some View {
        TabView(selection: $router.selectedTab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack {
                    HomeView(operations: database.operations)
                        .toolbar { newOperationButton }
                }
            }
            Tab("Storico", systemImage: "list.bullet.rectangle", value: AppTab.history) {
                NavigationStack(path: $router.historyPath) {
                    HistoryView()
                        .toolbar { newOperationButton }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .newOperationAccessory { router.newOperation() }
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
        .onAppear { router.selectedTab = storedTab }
        .onChange(of: router.selectedTab) { _, tab in storedTab = tab }
    }

    /// Azione, non sezione: sta nella toolbar e non nella tab bar (§ 7.2, Opzione A).
    private var newOperationButton: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Nuova operazione", systemImage: "plus") { router.newOperation() }
        }
    }
}

private extension View {
    /// Su iOS/iPadOS 26+: pulsante sopra la tab bar, sempre a portata di pollice (§ 7.2).
    @ViewBuilder
    func newOperationAccessory(action: @escaping () -> Void) -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            tabViewBottomAccessory {
                Button("Nuova operazione", systemImage: "plus", action: action)
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}
