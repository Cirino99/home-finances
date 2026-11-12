import AppSecurity
import Core
import SwiftUI

/// Impostazioni (§ 8.6). Export e import li esegue la radice dell'app: qui si chiedono soltanto.
public struct SettingsView: View {
    private let appLock: AppLock
    private let categories: any CategoryRepository
    private let accounts: any AccountRepository
    private let transfers: any TransferRepository
    private let movements: any MovementRepository
    private let hasBackup: Bool
    @Binding private var isIncludedInSystemBackup: Bool
    @State private var currency: String?
    @State private var biometricFailed = false
    @State private var isConfirmingUndo = false
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @AppStorage(AutoLockTimeout.storageKey) private var autoLockTimeout = AutoLockTimeout.default
    #endif

    public init(
        appLock: AppLock,
        categories: any CategoryRepository,
        accounts: any AccountRepository,
        transfers: any TransferRepository,
        movements: any MovementRepository,
        hasBackup: Bool,
        isIncludedInSystemBackup: Binding<Bool>
    ) {
        self.appLock = appLock
        self.categories = categories
        self.accounts = accounts
        self.transfers = transfers
        self.movements = movements
        self.hasBackup = hasBackup
        _isIncludedInSystemBackup = isIncludedInSystemBackup
    }

    public var body: some View {
        NavigationStack {
            Form {
                securitySection
                dataSection
                Section {
                    Toggle("Includi nei backup di sistema", isOn: $isIncludedInSystemBackup)
                } footer: {
                    Text(
                        isIncludedInSystemBackup
                            ? "I dati finiscono nei backup di iCloud, del Mac e di Time Machine, così non si perdono cambiando dispositivo. L'app non li cifra: la protezione dipende da quella dei backup."
                            : "I dati non finiscono nei prossimi backup: se perdi il dispositivo li perdi, salvo aver esportato un file. I backup già fatti non cambiano."
                    )
                }
                Section("Generale") {
                    LabeledContent("Valuta", value: currency ?? "—")
                }
                Section("Informazioni") {
                    LabeledContent("Versione", value: appVersion)
                    Text("I tuoi dati non lasciano mai questo dispositivo.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Impostazioni")
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
        .alert("\(appLock.biometry.displayName) non attivato", isPresented: $biometricFailed) {
            Button("OK", role: .cancel) {}
        }
        .task {
            do {
                for try await value in accounts.observeAccounts(includingArchived: true) {
                    currency = value.first?.currency
                }
            } catch {
                currency = nil
            }
        }
    }

    private var securitySection: some View {
        Section("Sicurezza") {
            if appLock.biometry != .unavailable {
                Toggle("Sblocco con \(appLock.biometry.displayName)", isOn: biometricBinding)
            }
            NavigationLink("Cambia PIN") {
                ChangePINView(appLock: appLock)
            }
            #if os(macOS)
            Picker("Blocco automatico", selection: $autoLockTimeout) {
                ForEach(AutoLockTimeout.allCases, id: \.self) { timeout in
                    Text("\(timeout.rawValue) min").tag(timeout)
                }
            }
            #endif
        }
    }

    private var dataSection: some View {
        Section("Dati") {
            NavigationLink("Gestisci categorie") {
                CategoriesView(repository: categories)
            }
            NavigationLink("Gestisci conti") {
                AccountsCatalogView(repository: accounts, transfers: transfers, movements: movements, currency: currency)
            }
            Button("Esporta database") { request(.exportDatabase) }
            Button("Importa database") { request(.importDatabase) }
            Button("Annulla ultimo import") { isConfirmingUndo = true }
                .disabled(!hasBackup)
                // Sul pulsante: su iOS 26 la conferma è un popover che punta a chi la apre.
                .confirmationDialog(
                    "Annullare l'ultimo import?",
                    isPresented: $isConfirmingUndo,
                    titleVisibility: .visible
                ) {
                    Button("Ripristina i dati precedenti", role: .destructive) { request(.undoImport) }
                } message: {
                    Text("Torneranno i dati di prima dell'ultimo import. Le modifiche fatte dopo andranno perse.")
                }
            Button("Esporta CSV") { request(.exportCSV) }
        }
    }

    /// Su iPhone e iPad l'azione parte quando questo sheet si è chiuso.
    private func request(_ dataRequest: DataTransferRequest) {
        router.dataTransferRequest = dataRequest
        #if os(iOS)
        dismiss()
        #endif
    }

    private var biometricBinding: Binding<Bool> {
        Binding(
            get: { appLock.isBiometricUnlockEnabled },
            set: { isOn in
                if isOn {
                    Task {
                        do {
                            try await appLock.enableBiometricUnlock()
                        } catch {
                            biometricFailed = true
                        }
                    }
                } else {
                    try? appLock.disableBiometricUnlock()
                }
            }
        )
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}
