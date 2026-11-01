import SwiftUI

/// Storico provvisorio: Operazioni, Mesi e Anni arrivano nello Sprint 5 (§ 8.3).
public struct HistoryView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView("Storico in arrivo", systemImage: "list.bullet.rectangle")
            .navigationTitle("Storico")
    }
}
