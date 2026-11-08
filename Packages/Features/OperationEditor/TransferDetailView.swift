import Core
import DesignSystem
import SwiftUI

/// Dettaglio di un trasferimento (§ 8.8). Si aggiorna da solo dopo una modifica.
public struct TransferDetailView: View {
    private let id: TransferID
    private let transfers: any TransferRepository
    private let onDeleted: (() -> Void)?
    @State private var item: TransferListItem?
    @State private var hasLoaded = false
    @State private var isConfirmingDelete = false
    @State private var deleteFailed = false
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    /// `onDeleted` sostituisce il ritorno indietro, dove non basta: la colonna di dettaglio
    /// di una split view non ha una schermata precedente.
    public init(id: TransferID, transfers: any TransferRepository, onDeleted: (() -> Void)? = nil) {
        self.id = id
        self.transfers = transfers
        self.onDeleted = onDeleted
    }

    public var body: some View {
        Group {
            if let item {
                details(item)
            } else if hasLoaded {
                ContentUnavailableView("Trasferimento non disponibile", systemImage: "exclamationmark.triangle")
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
                    Button("Modifica") { router.editor = .editTransfer(id) }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Elimina", systemImage: "trash", role: .destructive) {
                        isConfirmingDelete = true
                    }
                    .confirmationDialog(
                        "Eliminare questo trasferimento?",
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
                for try await value in transfers.observeItem(id) {
                    item = value
                    hasLoaded = true
                }
            } catch {
                hasLoaded = true
            }
        }
    }

    private func details(_ item: TransferListItem) -> some View {
        let transfer = item.transfer
        return List {
            Section {
                VStack(spacing: 12) {
                    // Senza segno: per il totale un trasferimento non cambia nulla (§ 8.3).
                    Text(MoneyFormat.string(minorUnits: transfer.amount, currency: transfer.currency))
                        .font(.largeTitle.bold())
                        .monospacedDigit()
                        .foregroundStyle(Color.transfer)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        TransferIcon()
                        Text("Trasferimento")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
                .accessibilityElement(children: .combine)
            }

            Section {
                LabeledContent("Da", value: item.fromAccountName)
                LabeledContent("A", value: item.toAccountName)
                LabeledContent("Data", value: DayFormat.long(transfer.date))
                if let note = transfer.note {
                    LabeledContent("Nota", value: note)
                }
            }

            Section {
                LabeledContent("Creato", value: transfer.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Modificato", value: transfer.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func delete() {
        Task {
            do {
                try await transfers.delete(id)
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
