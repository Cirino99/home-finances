import Core
import SwiftUI

/// Confronto tra i dati attuali e il file da importare, da confermare (§ 10.4).
public struct ImportConfirmationView: View {
    private let preview: ImportPreview
    private let onConfirm: () -> Void
    private let onCancel: () -> Void

    public init(preview: ImportPreview, onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.preview = preview
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack {
            Form {
                if preview.currentIsNewer {
                    warning(lastModifiedWarning)
                }
                if preview.isDifferentDatabase {
                    warning("Il file viene da un database creato altrove: non è una copia di quello su questo dispositivo.")
                }
                summarySection("Dati attuali (questo dispositivo)", summary: preview.current)
                summarySection("File da importare", summary: preview.incoming)
                Section {
                    Button("Sostituisci i dati", role: .destructive, action: onConfirm)
                } footer: {
                    Text("Tutti i dati attuali verranno sostituiti. Resta una copia di sicurezza, ripristinabile dalle Impostazioni con \"Annulla ultimo import\".")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Importa database")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        // Una scelta che sostituisce i dati va fatta con un gesto esplicito.
        .interactiveDismissDisabled()
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }

    private var lastModifiedWarning: String {
        let date = preview.current.lastModifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? ""
        return "I dati su questo dispositivo sono più recenti del file. Importando perderai le modifiche successive al \(date)."
    }

    private func warning(_ text: String) -> some View {
        Section {
            Label {
                Text(text)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func summarySection(_ title: LocalizedStringKey, summary: DatabaseSummary) -> some View {
        Section(title) {
            LabeledContent("Ultima modifica", value: lastModifiedText(summary))
            LabeledContent("Movimenti", value: String(summary.movementCount))
            LabeledContent("Movimento più recente", value: summary.latestMovementDate.map { DayFormat.long($0) } ?? "—")
        }
    }

    private func lastModifiedText(_ summary: DatabaseSummary) -> String {
        guard let date = summary.lastModifiedAt else { return "—" }
        let text = date.formatted(date: .abbreviated, time: .shortened)
        guard let device = summary.lastModifiedBy, !device.isEmpty else { return text }
        return "\(text), \(device)"
    }
}
