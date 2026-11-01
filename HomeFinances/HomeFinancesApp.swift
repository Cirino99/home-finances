import AppSecurity
import Persistence
import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct HomeFinancesApp: App {
    @State private var databaseState: DatabaseState
    @State private var appLock: AppLock

    init() {
        let databaseState = DatabaseState.open()
        _databaseState = State(initialValue: databaseState)
        _appLock = State(initialValue: AppLock(
            store: KeychainStore(service: "\(Bundle.main.bundleIdentifier ?? "HomeFinances").security"),
            authenticator: SystemBiometricAuthenticator(),
            hasExistingData: databaseState.hasExistingData
        ))
    }

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

    @MainActor
    static func open() -> DatabaseState {
        do {
            let bundleID = Bundle.main.bundleIdentifier ?? "HomeFinances"
            let url = try AppDatabase.defaultURL(bundleIdentifier: bundleID)
            return .ready(try AppDatabase.open(at: url, deviceName: deviceName))
        } catch {
            return .failed(error)
        }
    }

    /// Database con dati ma senza PIN significa ripristino da backup (§ 5.5). Se la lettura fallisce
    /// si assume che i dati ci siano: chiedere il codice del dispositivo è il caso più prudente.
    var hasExistingData: Bool {
        switch self {
        case .ready(let database): (try? database.isSeeded()) ?? true
        case .failed: false
        }
    }

    /// Per `last_modified_by`, mostrato nel confronto prima di un import (§ 10.4).
    @MainActor
    private static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }
}
