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
                .frame(minWidth: 760, minHeight: 500)
        }
        .commands {
            AppCommands(appLock: appLock, router: router)
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
        // Le scorciatoie valgono anche con una tastiera esterna su iPad (§ 7.4).
        .commands {
            AppCommands(appLock: appLock, router: router)
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

/// Voci di menu e scorciatoie (§ 7.4). Niente è attivo finché l'app è bloccata.
private struct AppCommands: Commands {
    let appLock: AppLock
    let router: AppRouter

    private var isLocked: Bool {
        appLock.phase != .unlocked
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nuova operazione") { router.newOperation() }
                .keyboardShortcut("n")
                .disabled(isLocked)
            #if os(macOS)
            Button("Esporta database…") { router.transferRequest = .exportDatabase }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(isLocked)
            Button("Importa database…") { router.transferRequest = .importDatabase }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(isLocked)
            #endif
        }
        CommandGroup(after: .textEditing) {
            Button("Cerca") { router.requestSearch() }
                .keyboardShortcut("f")
                .disabled(isLocked)
        }
        CommandGroup(before: .sidebar) {
            Button("Home") { router.selectedTab = .home }
                .keyboardShortcut("1")
                .disabled(isLocked)
            Button("Storico") { router.selectedTab = .history }
                .keyboardShortcut("2")
                .disabled(isLocked)
            Divider()
        }
        #if os(macOS)
        CommandGroup(replacing: .appSettings) {
            OpenSettingsButton()
            Button("Blocca") { appLock.lock() }
                .keyboardShortcut("l", modifiers: [.command, .control])
                .disabled(isLocked)
        }
        #endif
    }
}
