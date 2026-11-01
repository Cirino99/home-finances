import AppSecurity
import Core
import LockFeature
import Persistence
import SettingsFeature
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

extension UTType {
    /// Dichiarato in Info.plist (§ 10.2).
    static let homeFinancesDatabase = UTType(exportedAs: "it.simonecirino.homefinances.database")
}

/// Esegue export e import (§ 10). Sta sotto la radice sbloccata: finché l'app è bloccata non parte nulla.
struct DataTransferPresenter: ViewModifier {
    private struct ExportedFile: Identifiable {
        let url: URL
        var id: URL { url }
    }

    private struct PendingExport {
        let password: String?
    }

    /// File protetto in attesa della password.
    private struct PasswordPrompt {
        let source: URL
        let wasWrong: Bool
    }

    let database: AppDatabase
    let store: DatabaseStore
    let appLock: AppLock
    @Bindable var router: AppRouter
    @State private var isShowingExportOptions = false
    /// Scelta fatta nelle opzioni: l'export parte quando lo sheet si è chiuso.
    @State private var pendingExport: PendingExport?
    @State private var passwordPrompt: PasswordPrompt?
    @State private var enteredPassword = ""
    @State private var isImporterPresented = false
    @State private var exportedFile: ExportedFile?
    @State private var preview: ImportPreview?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $router.isSettingsPresented, onDismiss: processRequests) {
                SettingsView(
                    appLock: appLock,
                    categories: database.categories,
                    accounts: database.accounts,
                    hasBackup: store.hasBackup
                )
                // Lo sheet è presentato da qui: non eredita l'ambiente impostato sul contenuto.
                .environment(router)
                .privacyCover(appLock.isPrivacyCovered)
            }
            .sheet(item: $preview) { preview in
                ImportConfirmationView(
                    preview: preview,
                    onConfirm: { performImport(preview) },
                    onCancel: {
                        store.cancelImport(preview)
                        self.preview = nil
                    }
                )
                .privacyCover(appLock.isPrivacyCovered)
            }
            .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.homeFinancesDatabase]) { result in
                switch result {
                case .success(let url):
                    prepareImport(from: url)
                case .failure(let error):
                    router.transferMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $isShowingExportOptions, onDismiss: startPendingExport) {
                ExportOptionsView(
                    onExport: { password in
                        pendingExport = PendingExport(password: password)
                        isShowingExportOptions = false
                    },
                    onCancel: { isShowingExportOptions = false }
                )
                .privacyCover(appLock.isPrivacyCovered)
            }
            .alert(
                passwordPrompt?.wasWrong == true ? "Password errata" : "File protetto",
                isPresented: Binding(
                    get: { passwordPrompt != nil },
                    set: { isPresented in
                        if !isPresented {
                            passwordPrompt = nil
                            enteredPassword = ""
                        }
                    }
                )
            ) {
                SecureField("Password", text: $enteredPassword)
                Button("Importa") { submitPassword() }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("Inserisci la password scelta quando il file è stato esportato.")
            }
            #if os(iOS)
            .sheet(item: $exportedFile, onDismiss: nil) { file in
                ShareSheet(url: file.url) {
                    store.removeTemporaryFile(file.url)
                    exportedFile = nil
                }
                .privacyCover(appLock.isPrivacyCovered)
            }
            #else
            // Sposta il file temporaneo dove sceglie l'utente: non ne resta una copia.
            .fileMover(
                isPresented: Binding(
                    get: { exportedFile != nil },
                    set: { isPresented in
                        if !isPresented, let file = exportedFile {
                            store.removeTemporaryFile(file.url)
                            exportedFile = nil
                        }
                    }
                ),
                file: exportedFile?.url
            ) { result in
                if case .failure(let error) = result {
                    router.transferMessage = error.localizedDescription
                }
            }
            #endif
            .onAppear(perform: processRequests)
            .onChange(of: router.transferRequest) { processRequests() }
            .onChange(of: router.pendingImportURL) { processRequests() }
    }

    /// Le richieste aspettano che le Impostazioni siano chiuse: un pannello non si apre sopra uno sheet che si chiude.
    private func processRequests() {
        guard !router.isSettingsPresented else { return }
        if let url = router.pendingImportURL {
            router.pendingImportURL = nil
            router.editor = nil
            prepareImport(from: url)
        }
        guard let request = router.transferRequest else { return }
        router.transferRequest = nil
        switch request {
        case .exportDatabase:
            isShowingExportOptions = true
        case .importDatabase:
            isImporterPresented = true
        case .exportCSV:
            run {
                exportedFile = ExportedFile(url: try await store.exportCSV())
            }
        case .undoImport:
            run {
                let count = try await store.undoLastImport()
                router.resetNavigation()
                router.transferMessage = String(localized: "Dati ripristinati: \(count) operazioni")
            }
        }
    }

    private func startPendingExport() {
        guard let export = pendingExport else { return }
        pendingExport = nil
        run {
            exportedFile = ExportedFile(url: try await store.exportDatabase(password: export.password))
        }
    }

    private func prepareImport(from url: URL, password: String? = nil) {
        Task {
            do {
                preview = try await store.prepareImport(from: url, password: password)
            } catch DataTransferError.passwordRequired {
                passwordPrompt = PasswordPrompt(source: url, wasWrong: false)
            } catch DataTransferError.wrongPassword {
                passwordPrompt = PasswordPrompt(source: url, wasWrong: true)
            } catch {
                router.transferMessage = error.localizedDescription
            }
        }
    }

    private func submitPassword() {
        guard let prompt = passwordPrompt else { return }
        let password = enteredPassword
        enteredPassword = ""
        passwordPrompt = nil
        prepareImport(from: prompt.source, password: password)
    }

    private func performImport(_ preview: ImportPreview) {
        self.preview = nil
        run {
            let count = try await store.performImport(preview)
            router.resetNavigation()
            router.transferMessage = String(localized: "Dati importati: \(count) operazioni")
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                router.transferMessage = error.localizedDescription
            }
        }
    }
}

#if os(iOS)
/// Foglio di condivisione di sistema: AirDrop, Salva su File, Mail, Messaggi (§ 10.3).
/// Non `ShareLink`, che non dice quando ha finito: il file temporaneo va eliminato subito dopo.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onFinish: @MainActor () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            MainActor.assumeIsolated { onFinish() }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
