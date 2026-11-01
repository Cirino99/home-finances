import Core
import DesignSystem
import SwiftUI

/// Dettaglio di un'operazione (§ 8.4). Si aggiorna da solo dopo una modifica.
public struct OperationDetailView: View {
    private let id: OperationID
    private let operations: any OperationRepository
    private let onDeleted: (() -> Void)?
    @State private var item: OperationListItem?
    @State private var hasLoaded = false
    @State private var isConfirmingDelete = false
    @State private var deleteFailed = false
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    /// `onDeleted` sostituisce il ritorno indietro, dove non basta: la colonna di dettaglio
    /// di una split view non ha una schermata precedente.
    public init(id: OperationID, operations: any OperationRepository, onDeleted: (() -> Void)? = nil) {
        self.id = id
        self.operations = operations
        self.onDeleted = onDeleted
    }

    public var body: some View {
        Group {
            if let item {
                details(item)
            } else if hasLoaded {
                ContentUnavailableView("Operazione non disponibile", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Dettaglio")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if item != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Modifica") { router.editor = .edit(id) }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Elimina", systemImage: "trash", role: .destructive) {
                        isConfirmingDelete = true
                    }
                    .confirmationDialog(
                        "Eliminare questa operazione?",
                        isPresented: $isConfirmingDelete,
                        titleVisibility: .visible
                    ) {
                        Button("Elimina", role: .destructive, action: delete)
                    }
                }
            }
        }
        .alert("Eliminazione non riuscita", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        }
        .task {
            do {
                for try await value in operations.observeItem(id) {
                    item = value
                    hasLoaded = true
                }
            } catch {
                hasLoaded = true
            }
        }
    }

    private func details(_ item: OperationListItem) -> some View {
        let operation = item.operation
        return List {
            Section {
                VStack(spacing: 12) {
                    Text(MoneyFormat.string(
                        amount: operation.amount,
                        kind: operation.kind,
                        currency: operation.currency
                    ))
                    .font(.largeTitle.bold())
                    .monospacedDigit()
                    .foregroundStyle(operation.kind.color)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                    HStack(spacing: 8) {
                        CategoryIcon(symbol: item.category.symbol, color: item.category.color)
                        Text(item.category.name)
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
            }

            Section {
                LabeledContent("Data", value: DayFormat.long(operation.date))
                LabeledContent("Conto", value: item.accountName)
                if let note = operation.note {
                    LabeledContent("Nota", value: note)
                }
            }

            Section {
                LabeledContent("Creata", value: operation.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Modificata", value: operation.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func delete() {
        Task {
            do {
                try await operations.delete(id)
                if let onDeleted {
                    onDeleted()
                } else {
                    dismiss()
                }
            } catch {
                deleteFailed = true
            }
        }
    }
}
