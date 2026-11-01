import SwiftUI

/// Ultimo passo del primo avvio: la valuta dell'app, unica in v1 (§ 6.1, § 8.1).
///
/// Compare dopo lo sblocco finché il database non ha i dati iniziali: così, se l'app viene chiusa
/// a metà onboarding, il passo viene riproposto al riavvio invece di lasciare un database vuoto.
public struct CurrencySetupView: View {
    private let onConfirm: @MainActor (String) async throws -> Void
    private let currencies: [String]
    @State private var currency: String
    @State private var isWorking = false
    @State private var failed = false

    public init(
        defaultCurrency: String = Locale.current.currency?.identifier ?? "EUR",
        onConfirm: @escaping @MainActor (String) async throws -> Void
    ) {
        self.onConfirm = onConfirm
        let locale = Locale.current
        currencies = Set(Locale.commonISOCurrencyCodes + [defaultCurrency]).sorted {
            (locale.localizedString(forCurrencyCode: $0) ?? $0)
                .localizedCaseInsensitiveCompare(locale.localizedString(forCurrencyCode: $1) ?? $1) == .orderedAscending
        }
        _currency = State(initialValue: defaultCurrency)
    }

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "dollarsign.circle")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Scegli la valuta")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("Sarà usata per tutti i tuoi importi e non potrà essere cambiata dopo la prima operazione.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Picker("Valuta", selection: $currency) {
                ForEach(currencies, id: \.self) { code in
                    Text(label(for: code)).tag(code)
                }
            }
            .labelsHidden()
            if failed {
                Text("Operazione non riuscita. Riprova.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Spacer()
            Button("Continua", action: confirm)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isWorking)
        }
        .padding()
        .frame(maxWidth: 480, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }

    private func label(for code: String) -> String {
        guard let name = Locale.current.localizedString(forCurrencyCode: code) else { return code }
        return "\(name) (\(code))"
    }

    private func confirm() {
        isWorking = true
        failed = false
        Task {
            defer { isWorking = false }
            do {
                try await onConfirm(currency)
            } catch {
                failed = true
            }
        }
    }
}
