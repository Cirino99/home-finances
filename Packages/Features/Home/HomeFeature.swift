import Core
import DesignSystem
import SwiftUI

/// Home provvisoria: aggiunta rapida e ultime operazioni, per inserirle e modificarle.
/// Riepilogo del mese e selettore arrivano nello Sprint 4 (§ 8.2).
public struct HomeView: View {
    private let operations: any OperationRepository
    @Environment(AppRouter.self) private var router
    @State private var items: [OperationListItem] = []
    @State private var loadFailed = false

    public init(operations: any OperationRepository) {
        self.operations = operations
    }

    public var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    quickAdd("Entrata", kind: .income)
                    quickAdd("Uscita", kind: .expense)
                }
                .buttonStyle(.bordered)
            }
            Section("Ultime operazioni") {
                ForEach(items) { item in
                    Button {
                        router.editor = .edit(item.id)
                    } label: {
                        OperationRow(item: item)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("Nessuna operazione", systemImage: "tray")
                } description: {
                    if loadFailed {
                        Text("Non è stato possibile caricare i dati.")
                    }
                } actions: {
                    Button("Aggiungi la prima") { router.newOperation() }
                }
            }
        }
        .navigationTitle("Home")
        .task {
            do {
                for try await value in operations.observeRecent(limit: 20) {
                    items = value
                }
            } catch {
                loadFailed = true
            }
        }
    }

    private func quickAdd(_ title: LocalizedStringKey, kind: OperationKind) -> some View {
        Button {
            router.newOperation(kind: kind)
        } label: {
            Label(title, systemImage: "plus")
                .frame(maxWidth: .infinity)
        }
    }
}
