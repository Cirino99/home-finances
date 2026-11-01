import AppSecurity
import DesignSystem
import OSLog
import SwiftUI

/// Primo avvio (§ 8.1): benvenuto, PIN con conferma, proposta di Face ID / Touch ID.
/// La scelta della valuta segue dopo lo sblocco: vedi `CurrencySetupView`.
struct OnboardingView: View {
    private enum Step {
        case welcome
        case restore
        case choosePIN
        case confirmPIN
        case biometrics
    }

    let appLock: AppLock
    @State private var step: Step
    @State private var pin = ""
    @State private var firstPIN = ""
    @State private var failureCount = 0
    @State private var message: String?
    @State private var isWorking = false

    init(appLock: AppLock, reason: AppLock.SetupReason) {
        self.appLock = appLock
        _step = State(initialValue: reason == .restoredData ? .restore : .welcome)
    }

    var body: some View {
        Group {
            switch step {
            case .welcome:
                welcome
            case .restore:
                restore
            case .choosePIN:
                pinStep(title: "Scegli un PIN", subtitle: "6 cifre, per sbloccare l'app.", onComplete: choose)
            case .confirmPIN:
                pinStep(title: "Conferma il PIN", subtitle: "Inseriscilo di nuovo.", onComplete: confirm)
            case .biometrics:
                biometrics
            }
        }
        .padding()
        .frame(maxWidth: 480, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .animation(.default, value: step)
    }

    // MARK: Passi

    private var welcome: some View {
        stepLayout(
            symbol: "lock.shield",
            title: "Benvenuto in Home Finances",
            text: "I tuoi dati restano solo su questo dispositivo: nessun server, nessun account. L'accesso è protetto da un PIN e, se vuoi, da \(biometryName)."
        ) {
            Button("Inizia") { step = .choosePIN }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private var restore: some View {
        stepLayout(
            symbol: "arrow.clockwise.icloud",
            title: "Dati trovati",
            text: "Su questo dispositivo ci sono dati di Home Finances ma nessun PIN, ad esempio dopo un ripristino da backup. Per proteggerli, conferma la tua identità e scegli un nuovo PIN."
        ) {
            Button("Continua") {
                run {
                    try await appLock.authorizeRestore()
                    step = .choosePIN
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isWorking)
        }
    }

    private var biometrics: some View {
        stepLayout(
            symbol: appLock.biometry.symbolName,
            title: "Sbloccare con \(biometryName)?",
            text: "Potrai sempre usare il PIN e cambiare la scelta nelle Impostazioni."
        ) {
            VStack(spacing: 12) {
                Button("Attiva \(biometryName)") {
                    run {
                        try await appLock.enableBiometricUnlock()
                        appLock.finishSetup()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Non ora") { appLock.finishSetup() }
                    .controlSize(.large)
            }
            .disabled(isWorking)
        }
    }

    private func pinStep(title: String, subtitle: String, onComplete: @escaping (String) -> Void) -> some View {
        VStack(spacing: 32) {
            VStack(spacing: 12) {
                Text(title)
                    .font(.title2.bold())
                Text(message ?? subtitle)
                    .font(.callout)
                    .foregroundStyle(message == nil ? Color.secondary : Color.red)
                    .multilineTextAlignment(.center)
            }
            PINEntryView(pin: $pin, isEnabled: !isWorking, failureCount: failureCount, onComplete: onComplete)
        }
    }

    private func stepLayout(
        symbol: String,
        title: String,
        text: String,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text(title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            actions()
        }
    }

    // MARK: Azioni

    private func choose(_ entered: String) {
        firstPIN = entered
        pin = ""
        message = nil
        step = .confirmPIN
    }

    private func confirm(_ entered: String) {
        pin = ""
        guard entered == firstPIN else {
            firstPIN = ""
            failureCount += 1
            message = "I PIN non coincidono. Riprova."
            step = .choosePIN
            return
        }
        run {
            try await appLock.setInitialPIN(entered)
            if appLock.biometry == .unavailable {
                appLock.finishSetup()
            } else {
                step = .biometrics
            }
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                try await action()
            } catch {
                Logger(subsystem: "HomeFinances", category: "Onboarding").error("Onboarding non riuscito: \(String(describing: error), privacy: .public)")
                #if DEBUG
                message = "Operazione non riuscita. Riprova.\n\(String(describing: error))"
                #else
                message = "Operazione non riuscita. Riprova."
                #endif
            }
        }
    }

    private var biometryName: String {
        appLock.biometry == .unavailable ? "Face ID o Touch ID" : appLock.biometry.displayName
    }
}
 
