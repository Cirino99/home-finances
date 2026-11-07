import Core
import DesignSystem
import SwiftUI

/// Nuova o modifica operazione (§ 8.5). Presentata in uno sheet dalla radice dell'app.
public struct OperationEditorView: View {
    @State private var model: OperationEditorModel
    @State private var isConfirmingDiscard = false
    @Environment(\.dismiss) private var dismiss
    private let onSaved: () -> Void

    public init(model: OperationEditorModel, onSaved: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onSaved = onSaved
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.isEditing ? "Modifica operazione" : "Nuova operazione")
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
        .frame(minWidth: 460, minHeight: 560)
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
                "Operazione non disponibile",
                systemImage: "exclamationmark.triangle",
                description: Text("Non è stato possibile caricare i dati.")
            )
        case .ready:
            form
        }
    }

    private var form: some View {
        @Bindable var model = model
        return Form {
            Section {
                Picker("Tipo", selection: $model.kind) {
                    Text("Uscita").tag(OperationKind.expense)
                    Text("Entrata").tag(OperationKind.income)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                AmountField(text: $model.amountText, currency: model.currency)
            }

            Section("Categoria") {
                CategoryGrid(categories: model.visibleCategories, selection: $model.categoryID)
            }

            Section {
                DatePicker("Data", selection: $model.date, displayedComponents: .date)
                if model.showsAccountPicker {
                    Picker("Conto", selection: $model.accountID) {
                        ForEach(model.visibleAccounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }
                }
            }

            Section {
                TextField("Nota", text: $model.note, axis: .vertical)
                    .lineLimit(1...4)
            } footer: {
                if model.note.count > OperationDraft.maxNoteLength {
                    Text("Massimo \(OperationDraft.maxNoteLength) caratteri.")
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

private struct CategoryGrid: View {
    let categories: [OperationCategory]
    @Binding var selection: CategoryID?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), alignment: .top)], spacing: 12) {
            ForEach(categories) { category in
                Button {
                    selection = category.id
                } label: {
                    VStack(spacing: 6) {
                        CategoryIcon(symbol: category.symbol, color: category.color)
                        Text(category.name)
                            .font(.caption)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(
                        selection == category.id ? category.color.color.opacity(0.2) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(selection == category.id ? category.color.color : Color.clear, lineWidth: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == category.id ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}
