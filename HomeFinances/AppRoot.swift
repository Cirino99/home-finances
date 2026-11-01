import AppSecurity
import Core
import LockFeature
import Persistence
import SettingsFeature
import SwiftUI

/// Radice dell'app: blocco/sblocco e, una volta sbloccata, la navigazione principale.
struct AppRoot: View {
    let store: DatabaseStore
    let appLock: AppLock
    @Bindable var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    retryDatabase()
                }
            }
            // Un file `.homefinances` aperto dall'esterno: l'import parte solo a contenuto visibile, cioè dopo lo sblocco.
            .onOpenURL { url in
                router.pendingImportURL = url
            }
            .alert(
                "Dati",
                isPresented: Binding(
                    get: { router.transferMessage != nil },
                    set: { _ in router.transferMessage = nil }
                ),
                presenting: router.transferMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }

    private func retryDatabase() {
        store.retryIfNeeded()
        // Ora si può sapere se ci sono dati: può cambiare ciò che si deve chiedere.
        appLock.reload()
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .ready(let database):
            LockGate(appLock: appLock) {
                SeededContent(database: database, store: store, appLock: appLock, router: router)
                    // Dopo un import si riparte da zero: niente di ciò che era a schermo è più valido.
                    .id(store.generation)
            }
            .onChange(of: appLock.phase) { _, phase in
                if phase != .unlocked {
                    router.dismissPresentations()
                }
            }
        case .failed(let error):
            ContentUnavailableView {
                Label("Impossibile aprire il database", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("Riprova", action: retryDatabase)
            }
        }
    }
}

#if os(macOS)
/// Voce di menu Impostazioni… (⌘,).
struct OpenSettingsButton: View {
    static let windowID = "settings"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Impostazioni…") { openWindow(id: Self.windowID) }
            .keyboardShortcut(",")
    }
}
#endif

/// Finestra delle Impostazioni su Mac (⌘,). È separata da quella principale,
/// quindi deve rispettare il blocco per conto suo: niente dati finché l'app è bloccata.
struct MacSettingsRoot: View {
    let store: DatabaseStore
    let appLock: AppLock
    let router: AppRouter

    var body: some View {
        if appLock.phase == .unlocked, case .ready(let database) = store.state {
            SettingsView(
                appLock: appLock,
                categories: database.categories,
                accounts: database.accounts,
                hasBackup: store.hasBackup
            )
            .id(store.generation)
            .environment(router)
        } else {
            ContentUnavailableView(
                "App bloccata",
                systemImage: "lock.fill",
                description: Text("Sblocca Home Finances per vedere le impostazioni.")
            )
            .frame(minWidth: 480, minHeight: 320)
        }
    }
}

/// Chiede la valuta finché il database non ha i dati iniziali, poi mostra il contenuto.
private struct SeededContent: View {
    let database: AppDatabase
    let store: DatabaseStore
    let appLock: AppLock
    let router: AppRouter
    @State private var isSeeded: Bool

    init(database: AppDatabase, store: DatabaseStore, appLock: AppLock, router: AppRouter) {
        self.database = database
        self.store = store
        self.appLock = appLock
        self.router = router
        _isSeeded = State(initialValue: (try? database.isSeeded()) ?? false)
    }

    var body: some View {
        if isSeeded {
            RootTabView(database: database, store: store, appLock: appLock, router: router)
        } else {
            CurrencySetupView { currency in
                try await database.seedIfNeeded(currency: currency)
                isSeeded = true
            }
        }
    }
}
