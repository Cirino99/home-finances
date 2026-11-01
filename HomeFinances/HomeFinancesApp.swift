import AppSecurity
import Core
import Observation
import Persistence
import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct HomeFinancesApp: App {
    @State private var database: DatabaseStore
    @State private var appLock: AppLock
    @State private var router = AppRouter()

    init() {
        let database = DatabaseStore()
        _database = State(initialValue: database)
        let bundleID = Bundle.main.bundleIdentifier ?? "HomeFinances"
        _appLock = State(initialValue: AppLock(
            store: KeychainStore(service: "\(bundleID).security"),
            authenticator: SystemBiometricAuthenticator(service: "\(bundleID).security"),
            hasExistingData: { database.state.hasExistingData }
        ))
    }

    var body: some Scene {
        #if os(macOS)
        // Una sola finestra principale in v1 (§ 7.4).
        Window("Home Finances", id: "main") {
            AppRoot(database: database, appLock: appLock, router: router)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nuova operazione") { router.newOperation() }
                    .keyboardShortcut("n")
                    .disabled(appLock.phase != .unlocked)
            }
            CommandGroup(after: .appSettings) {
                Button("Blocca") { appLock.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .control])
                    .disabled(appLock.phase != .unlocked)
            }
        }
        #else
        WindowGroup {
            AppRoot(database: database, appLock: appLock, router: router)
        }
        #endif
    }
}

/// Apre il database e, se l'apertura fallisce, permette di riprovare: subito dopo un riavvio
/// iOS può avviare l'app quando il file non è ancora accessibile.
@MainActor
@Observable
final class DatabaseStore {
    private(set) var state: DatabaseState

    init() {
        state = DatabaseState.open()
    }

    func retryIfNeeded() {
        if case .failed = state {
            state = DatabaseState.open()
        }
    }
}

/// Esito dell'apertura del database.
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

    /// Database con dati ma senza PIN significa ripristino da backup (§ 5.5). Se il database non si può
    /// leggere si assume che i dati ci siano: è il caso più prudente, chiede il codice del dispositivo
    /// e non permette di reimpostare il PIN.
    var hasExistingData: Bool {
        switch self {
        case .ready(let database): (try? database.isSeeded()) ?? true
        case .failed: true
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
