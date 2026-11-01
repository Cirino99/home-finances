import SwiftUI

/// Scelte prima di esportare il database: con o senza password (§ 10.3).
public struct ExportOptionsView: View {
    public static let minimumPasswordLength = 8

    private let onExport: (String?) -> Void
    private let onCancel: () -> Void
    @State private var isProtected = true
    @State private var password = ""
    @State private var confirmation = ""

    /// `onExport` riceve la password, o `nil` per un file non protetto.
    public init(onExport: @escaping (String?) -> Void, onCancel: @escaping () -> Void) {
        self.onExport = onExport
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Proteggi con password", isOn: $isProtected)
                } footer: {
                    if !isProtected {
                        Text("Il file contiene tutti i tuoi dati finanziari e non è protetto da password. Conservalo e invialo solo in modo sicuro.")
                    }
                }
                if isProtected {
                    Section {
                        SecureField("Password", text: $password)
                            .autocorrectionDisabled()
                        SecureField("Conferma password", text: $confirmation)
                            .autocorrectionDisabled()
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            if let problem {
                                Text(problem)
                            }
                            Text("Se dimentichi la password il file non si potrà più aprire: non esiste un modo per recuperarla.")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Esporta database")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Esporta") { onExport(isProtected ? password : nil) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canExport)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }

    private var canExport: Bool {
        !isProtected || (password.count >= Self.minimumPasswordLength && password == confirmation)
    }

    private var problem: String? {
        if password.isEmpty { return nil }
        if password.count < Self.minimumPasswordLength {
            return "Usa almeno \(Self.minimumPasswordLength) caratteri."
        }
        if !confirmation.isEmpty, password != confirmation {
            return "Le password non coincidono."
        }
        return nil
    }
}
