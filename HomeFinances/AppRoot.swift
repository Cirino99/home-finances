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
                ContentUnavailableView {
                    Label("Database aperto", systemImage: "checkmark.seal")
                } description: {
                    Text("SQLite \((try? database.sqliteVersion()) ?? "?")")
                }
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
