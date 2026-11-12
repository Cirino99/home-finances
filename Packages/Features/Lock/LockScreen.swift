import AppSecurity
import DesignSystem
import SwiftUI

/// Sblocco con biometria o PIN (§ 8.1). Nessun dato finanziario è visibile qui.
struct LockScreen: View {
    let appLock: AppLock
    @Environment(\.scenePhase) private var scenePhase
    @State private var pin = ""
    @State private var failureCount = 0
    @State private var lastAttemptFailed = false
    @State private var isConfirmingReset = false
    @State private var resetFailed = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = appLock.lockedUntil.map { $0.timeIntervalSince(context.date) } ?? 0
            VStack(spacing: 32) {
                VStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                    Text("Inserisci il PIN")
                        .font(.title2.bold())
                    status(remaining: remaining)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 44, alignment: .top)
                }

                PINEntryView(
                    pin: $pin,
                    isEnabled: remaining <= 0 && !appLock.isBusy && appLock.loadError == nil,
                    failureCount: failureCount,
                    onComplete: submit
                ) {
                    if appLock.isBiometricUnlockEnabled {
                        Button {
                            Task { await appLock.unlockWithBiometrics() }
                        } label: {
                            Image(systemName: appLock.biometry.symbolName)
                                .font(.title)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(appLock.isBusy)
                        .accessibilityLabel("Usa \(appLock.biometry.displayName)")
                    }
                }

                if appLock.canResetForgottenPIN {
                    Button("Hai dimenticato il PIN?") { isConfirmingReset = true }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        // Sul pulsante: su iOS 26 la conferma è un popover che punta a chi la apre.
                        .confirmationDialog(
                            "Reimpostare il PIN?",
                            isPresented: $isConfirmingReset,
                            titleVisibility: .visible
                        ) {
                            Button("Continua") {
                                Task {
                                    do {
                                        try await appLock.resetForgottenPIN()
                                    } catch {
                                        resetFailed = true
                                    }
                                }
                            }
                        } message: {
                            Text("Questa app non contiene dati. Dopo aver confermato la tua identità potrai scegliere un nuovo PIN.")
                        }
                }
            }
            .padding()
            .scrollsIfNeeded()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("PIN non reimpostato", isPresented: $resetFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Non è stato possibile confermare la tua identità.")
        }
        .task(id: scenePhase) {
            // Al ritorno in primo piano, non durante il passaggio in background.
            if scenePhase == .active {
                await appLock.promptBiometricsIfNeeded()
            }
        }
    }

    @ViewBuilder
    private func status(remaining: TimeInterval) -> some View {
        if appLock.loadError != nil {
            Text("Impossibile leggere le credenziali. Sblocca il dispositivo e riprova.")
                .foregroundStyle(.red)
        } else if remaining > 0 {
            Text("Troppi tentativi errati.\n\(Self.retryMessage(remaining: remaining))")
                .foregroundStyle(.red)
        } else if lastAttemptFailed {
            Text("PIN errato")
                .foregroundStyle(.red)
        } else {
            Text(" ")
        }
    }

    private func submit(_ entered: String) {
        Task {
            let result = await appLock.unlock(withPIN: entered)
            pin = ""
            switch result {
            case .wrong, .lockedOut:
                lastAttemptFailed = true
                failureCount += 1
            case .success, nil:
                lastAttemptFailed = false
            }
        }
    }

    static func retryMessage(remaining: TimeInterval) -> String {
        let minutes = Int((remaining / 60).rounded(.up))
        return minutes == 1
            ? String(localized: "Riprova tra 1 minuto")
            : String(localized: "Riprova tra \(minutes) minuti")
    }
}
