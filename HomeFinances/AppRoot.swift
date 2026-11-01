import AppSecurity
import Core
import LockFeature
import Persistence
import SwiftUI

/// Radice dell'app: blocco/sblocco e, una volta sbloccata, la navigazione principale.
struct AppRoot: View {
    let database: DatabaseStore
    let appLock: AppLock
    let router: AppRouter
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    retryDatabase()
                }
            }
    }

    private func retryDatabase() {
        database.retryIfNeeded()
        // Ora si può sapere se ci sono dati: può cambiare ciò che si deve chiedere.
        appLock.reload()
    }

    @ViewBuilder
    private var content: some View {
        switch database.state {
        case .ready(let database):
            LockGate(appLock: appLock) {
                SeededContent(database: database, appLock: appLock, router: router)
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

/// Chiede la valuta finché il database non ha i dati iniziali, poi mostra il contenuto.
private struct SeededContent: View {
    let database: AppDatabase
    let appLock: AppLock
    let router: AppRouter
    @State private var isSeeded: Bool

    init(database: AppDatabase, appLock: AppLock, router: AppRouter) {
        self.database = database
        self.appLock = appLock
        self.router = router
        _isSeeded = State(initialValue: (try? database.isSeeded()) ?? false)
    }

    var body: some View {
        if isSeeded {
            RootTabView(database: database, appLock: appLock, router: router)
        } else {
            CurrencySetupView { currency in
                try await database.seedIfNeeded(currency: currency)
                isSeeded = true
            }
        }
    }
}
