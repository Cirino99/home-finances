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
        Task {
            await store.retryIfNeeded()
            // Ora si può sapere se ci sono dati: può cambiare ciò che si deve chiedere.
            appLock.reload()
        }
    }

    /// Il database si apre solo ad app sbloccata, con la chiave che lo sblocco ha dato (§ 5.7).
    private var content: some View {
        LockGate(appLock: appLock) {
            UnlockedContent(store: store, appLock: appLock, router: router)
        }
        .onChange(of: appLock.phase) { _, phase in
            if phase != .unlocked {
                router.dismissPresentations()
                // Il contenuto è già stato tolto da `LockGate`: si chiude il database e si dimentica la chiave.
                store.close()
            }
        }
    }
}

/// Apre il database con la chiave dello sblocco e mostra il contenuto, o perché non si apre.
private struct UnlockedContent: View {
    let store: DatabaseStore
    let appLock: AppLock
    let router: AppRouter

    var body: some View {
        switch store.state {
        case .closed:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    // Con la chiave, la prima volta cifra anche i dati di prima della cifratura (§ 5.7).
                    await store.open(encryptionKey: appLock.databaseKey?.sqlCipherKey)
                }
        case .ready(let database):
            SeededContent(database: database, store: store, appLock: appLock, router: router)
                // Dopo un import si riparte da zero: niente di ciò che era a schermo è più valido.
                .id(store.generation)
                .alert(
                    "Cifratura non completata",
                    isPresented: Binding(
                        get: { store.encryptionMigrationError != nil },
                        set: { if !$0 { store.dismissEncryptionMigrationError() } }
                    )
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Non è stato possibile cifrare i dati, per esempio per lo spazio esaurito. I dati sono intatti e restano protetti dal PIN come prima. Si riproverà al prossimo sblocco con il PIN.")
                }
        case .failed(let error as PersistenceError) where error == .keyMismatch:
            UnreadableDataView(store: store, appLock: appLock)
        case .failed(let error as PersistenceError) where error == .keyRequired:
            // Sbloccata con il vecchio token di Face ID, che non contiene la chiave: serve il PIN.
            ContentUnavailableView {
                Label("Inserisci il PIN", systemImage: "lock.fill")
            } description: {
                Text("Per aprire i dati serve il PIN, almeno questa volta.")
            } actions: {
                Button("Usa il PIN") { appLock.lock() }
            }
        case .failed(let error):
            ContentUnavailableView {
                Label("Impossibile aprire il database", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("Riprova") {
                    Task {
                        await store.retryIfNeeded()
                        appLock.reload()
                    }
                }
            }
        }
    }
}

/// Database cifrato con una chiave che questo dispositivo non ha (§ 5.7): di solito arriva dal backup di
/// un altro dispositivo, dove la chiave è rimasta. Non si apre in nessun modo: si può solo ricominciare,
/// e poi importare un file esportato dall'altro dispositivo.
private struct UnreadableDataView: View {
    let store: DatabaseStore
    let appLock: AppLock
    @State private var isConfirming = false
    @State private var isErasing = false
    @State private var eraseFailed = false

    var body: some View {
        ContentUnavailableView {
            Label("Dati di un altro dispositivo", systemImage: "lock.trianglebadge.exclamationmark")
        } description: {
            Text("I dati qui sono cifrati con una chiave che resta sul dispositivo dove sono stati creati, ad esempio perché vengono dal suo backup. Su questo dispositivo non si possono aprire.\n\nPer riaverli, esporta un file dal dispositivo di origine (Impostazioni › Dati › Esporta database), ricomincia da zero e importalo qui.")
        } actions: {
            Button("Ricomincia da zero", role: .destructive) { isConfirming = true }
                .disabled(isErasing)
                // Sul pulsante: su iOS 26 la conferma è un popover che punta a chi la apre.
                .confirmationDialog(
                    "Cancellare i dati di questo dispositivo?",
                    isPresented: $isConfirming,
                    titleVisibility: .visible
                ) {
                    Button("Cancella e ricomincia", role: .destructive, action: erase)
                } message: {
                    Text("I dati che non si possono aprire e le loro copie di sicurezza verranno cancellati. L'operazione non si può annullare.")
                }
        }
        .alert("Dati non cancellati", isPresented: $eraseFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Non è stato possibile confermare la tua identità o cancellare i file. Riprova.")
        }
    }

    private func erase() {
        isErasing = true
        Task {
            defer { isErasing = false }
            do {
                // Lo store si chiude: `UnlockedContent` lo riapre, e nasce un database vuoto cifrato
                // con la chiave di questo dispositivo. Poi la scelta della valuta, come al primo avvio.
                try await appLock.eraseUnreadableData()
            } catch {
                eraseFailed = true
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
                transfers: database.transfers,
                movements: database.movements,
                hasBackup: store.hasBackup,
                isIncludedInSystemBackup: store.systemBackupBinding
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

extension DatabaseStore {
    /// Per l'interruttore delle Impostazioni. Se non si può applicare, l'interruttore resta com'era.
    var systemBackupBinding: Binding<Bool> {
        Binding(
            get: { self.isIncludedInSystemBackup },
            set: { try? self.setIncludedInSystemBackup($0) }
        )
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
                // Da qui, con il database cifrato, "ci sono dati" anche ad app bloccata (§ 5.7).
                store.markSeeded()
                isSeeded = true
            }
        }
    }
}
