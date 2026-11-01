import AppSecurity
import Core
import Persistence
import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct HomeFinancesApp: App {
    @State private var store: DatabaseStore
    @State private var appLock: AppLock
    @State private var router = AppRouter()

    init() {
        let bundleID = Bundle.main.bundleIdentifier ?? "HomeFinances"
        let store = DatabaseStore(bundleIdentifier: bundleID, deviceName: Self.deviceName)
        _store = State(initialValue: store)
        _appLock = State(initialValue: AppLock(
            store: KeychainStore(service: "\(bundleID).security"),
            authenticator: SystemBiometricAuthenticator(service: "\(bundleID).security"),
            hasExistingData: { store.state.hasExistingData }
        ))
    }

    var body: some Scene {
        #if os(macOS)
        // Una sola finestra principale in v1 (§ 7.4).
        Window("Home Finances", id: "main") {
            AppRoot(store: store, appLock: appLock, router: router)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nuova operazione") { router.newOperation() }
                    .keyboardShortcut("n")
                    .disabled(appLock.phase != .unlocked)
            }
            CommandGroup(after: .newItem) {
                Button("Esporta database…") { router.transferRequest = .exportDatabase }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(appLock.phase != .unlocked)
                Button("Importa database…") { router.transferRequest = .importDatabase }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(appLock.phase != .unlocked)
            }
            CommandGroup(replacing: .appSettings) {
                OpenSettingsButton()
                Button("Blocca") { appLock.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .control])
                    .disabled(appLock.phase != .unlocked)
            }
        }

        // Finestra normale e non la scena `Settings`: lì la toolbar è centrata, compreso il tasto indietro.
        Window("Impostazioni", id: OpenSettingsButton.windowID) {
            MacSettingsRoot(store: store, appLock: appLock, router: router)
        }
        .defaultSize(width: 560, height: 640)
        .defaultLaunchBehavior(.suppressed)
        #else
        WindowGroup {
            AppRoot(store: store, appLock: appLock, router: router)
        }
        #endif
    }

    /// Per `last_modified_by`, mostrato nel confronto prima di un import (§ 10.4).
    private static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }
}
