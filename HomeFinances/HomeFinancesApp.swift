import AppSecurity
import Persistence
import SwiftUI

@main
struct HomeFinancesApp: App {
    @State private var databaseState = DatabaseState.open()
    @State private var appLock = AppLock(
        store: KeychainStore(service: "\(Bundle.main.bundleIdentifier ?? "HomeFinances").security"),
        authenticator: SystemBiometricAuthenticator(),
        // Diventa "il database contiene già dati" con lo schema v1 (Sprint 2), per il ripristino senza PIN (§ 5.5).
        hasExistingData: false
    )

    var body: some Scene {
        #if os(macOS)
        // Una sola finestra principale in v1 (§ 7.4).
        Window("Home Finances", id: "main") {
            AppRoot(databaseState: databaseState, appLock: appLock)
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Blocca") { appLock.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .control])
                    .disabled(appLock.phase != .unlocked)
            }
        }
        #else
        WindowGroup {
            AppRoot(databaseState: databaseState, appLock: appLock)
        }
        #endif
    }
}

/// Esito dell'apertura del database all'avvio.
enum DatabaseState {
    case ready(AppDatabase)
    case failed(any Error)

    static func open() -> DatabaseState {
        do {
            let bundleID = Bundle.main.bundleIdentifier ?? "HomeFinances"
            let url = try AppDatabase.defaultURL(bundleIdentifier: bundleID)
            return .ready(try AppDatabase.open(at: url))
        } catch {
            return .failed(error)
        }
    }
}
