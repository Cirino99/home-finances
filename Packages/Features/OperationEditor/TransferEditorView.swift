import Core
import DesignSystem
import SwiftUI

/// Nuovo o modifica trasferimento (§ 8.8). Presentato nello stesso sheet dell'editor di operazione.
public struct TransferEditorView: View {
    @State private var model: TransferEditorModel
    @State private var isConfirmingDiscard = false
    @Environment(\.dismiss) private var dismiss
    private let onSaved: () -> Void

    public init(model: TransferEditorModel, onSaved: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onSaved = onSaved
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.isEditing ? "Modifica trasferimento" : "Nuovo trasferimento")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Annulla", action: cancel)
                            .keyboardShortcut(.cancelAction)
                            .confirmationDialog(
                                "Scartare le modifiche?",
                                isPresented: $isConfirmingDiscard,
                                titleVisibility: .visible
                            ) {
                                Button("Scarta", role: .destructive) { dismiss() }
                                Button("Continua a modificare", role: .cancel) {}
                            }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Salva", action: save)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!model.canSave)
                    }
                }
        }
        .interactiveDismissDisabled(model.hasChanges)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
        .task {
            await model.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView(
                "Trasferimento non disponibile",
                systemImage: "exclamationmark.triangle",
                description: Text("Non è stato possibile caricare i dati.")
            )
        case .ready where model.hasTooFewAccounts:
            ContentUnavailableView(
                "Per trasferire servono almeno due conti",
                systemImage: "building.columns",
                description: Text("Aggiungi un conto in Impostazioni › Gestisci conti.")
            )
        case .ready:
            form
        }
    }

    private var form: some View {
        @Bindable var model = model
        return Form {
            Section {
                AmountField(text: $model.amountText, currency: model.currency)
            } footer: {
                if model.exceedsAvailableBalance, let available = model.availableBalance, let currency = model.currency {
                    Text("L'importo supera il saldo del conto di origine (\(MoneyFormat.string(minorUnits: available, currency: currency))).")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Picker("Da", selection: $model.fromAccountID) {
                    ForEach(model.visibleAccounts) { account in
                        accountLabel(account).tag(Optional(account.id))
                    }
                }
                Button("Inverti", systemImage: "arrow.up.arrow.down", action: model.swapAccounts)
                    .disabled(model.fromAccountID == nil || model.toAccountID == nil)
                Picker("A", selection: $model.toAccountID) {
                    ForEach(model.destinationAccounts) { account in
                        accountLabel(account).tag(Optional(account.id))
                    }
                }
            }

            Section {
                DatePicker("Data", selection: $model.date, displayedComponents: .date)
            }

            Section {
                TextField("Nota", text: $model.note, axis: .vertical)
                    .lineLimit(1...4)
            } footer: {
                if model.note.count > TransferDraft.maxNoteLength {
                    Text("Massimo \(TransferDraft.maxNoteLength) caratteri.")
                        .foregroundStyle(.red)
                }
            }

            if model.saveFailed {
                Section {
                    Text("Salvataggio non riuscito. Riprova.")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        // Trascinando il modulo verso il basso la tastiera segue il dito e si chiude.
        .scrollDismissesKeyboard(.interactively)
    }

    /// Nome e saldo: chi trasferisce vuole sapere quanto c'è (§ 8.8).
    private func accountLabel(_ account: Account) -> Text {
        guard let balance = model.balance(of: account.id) else {
            return Text(verbatim: account.name)
        }
        let amount = MoneyFormat.string(minorUnits: balance, currency: account.currency)
        return Text(verbatim: "\(account.name) · \(amount)")
    }

    private func cancel() {
        if model.hasChanges {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func save() {
        Task {
            if await model.save() {
                onSaved()
                dismiss()
            }
        }
    }
}
