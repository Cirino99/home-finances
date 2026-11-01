import AppSecurity
import LockFeature
import Persistence
import SwiftUI

/// Radice dell'app: blocco/sblocco; la TabView arriva nello Sprint 3.
struct AppRoot: View {
    let databaseState: DatabaseState
    let appLock: AppLock

    var body: some View {
        switch databaseState {
        case .ready(let database):
            LockGate(appLock: appLock) {
                SeededContent(database: database)
            }
        case .failed(let error):
            ContentUnavailableView {
                Label("Impossibile aprire il database", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            }
        }
    }
}

/// Chiede la valuta finché il database non ha i dati iniziali, poi mostra il contenuto.
private struct SeededContent: View {
    let database: AppDatabase
    @State private var isSeeded: Bool

    init(database: AppDatabase) {
        self.database = database
        _isSeeded = State(initialValue: (try? database.isSeeded()) ?? false)
    }

    var body: some View {
        if isSeeded {
            ContentUnavailableView {
                Label("Database aperto", systemImage: "checkmark.seal")
            } description: {
                Text("SQLite \((try? database.sqliteVersion()) ?? "?")")
            }
        } else {
            CurrencySetupView { currency in
                try await database.seedIfNeeded(currency: currency)
                isSeeded = true
            }
        }
    }
}
