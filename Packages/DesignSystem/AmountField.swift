import Core
import SwiftUI

/// Campo grande dell'importo negli editor (§ 8.5, § 8.8), con la valuta accanto.
/// Nessun focus automatico: la tastiera si apre solo toccando il campo.
public struct AmountField: View {
    @Binding private var text: String
    private let currency: String?

    public init(text: Binding<String>, currency: String?) {
        _text = text
        self.currency = currency
    }

    public var body: some View {
        HStack {
            if let currency {
                Text(currency)
                    .foregroundStyle(.secondary)
            }
            TextField("Importo", text: $text, prompt: Text(AmountInput.text(minorUnits: 0)))
                .font(.largeTitle)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .labelsHidden()
                #if os(iOS)
                .keyboardType(.decimalPad)
                #else
                // Nel Form raggruppato di macOS il campo resta alto quanto una riga di testo
                // normale: con il font grande le cifre escono in basso e la selezione
                // non le copre. Con lo stile plain l'altezza segue il font.
                .textFieldStyle(.plain)
                .fixedSize(horizontal: false, vertical: true)
                #endif
        }
    }
}

/// Icona dei trasferimenti, come `CategoryIcon` per le categorie (§ 8.8).
public struct TransferIcon: View {
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 34

    public init() {}

    public var body: some View {
        Image(systemName: "arrow.left.arrow.right")
            .font(.body)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.transfer, in: Circle())
            .accessibilityHidden(true)
    }
}
