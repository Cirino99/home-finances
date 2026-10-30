import Persistence
import SwiftUI

@main
struct HomeFinancesApp: App {
    @State private var databaseState = DatabaseState.open()

    var body: some Scene {
        #if os(macOS)
        // Una sola finestra principale in v1 (§ 7.4).
        Window("Home Finances", id: "main") {
            AppRoot(databaseState: databaseState)
        }
        #else
        WindowGroup {
            AppRoot(databaseState: databaseState)
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
