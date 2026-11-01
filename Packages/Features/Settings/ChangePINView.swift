import AppSecurity
import DesignSystem
import SwiftUI

/// Cambio del PIN (§ 8.6): attuale, nuovo e conferma. Il PIN attuale errato conta come tentativo fallito.
struct ChangePINView: View {
    private enum Step {
        case current
        case new
        case confirm
    }

    let appLock: AppLock
    @State private var step = Step.current
    @State private var pin = ""
    @State private var currentPIN = ""
    @State private var newPIN = ""
    @State private var failureCount = 0
    @State private var message: String?
    @State private var isWorking = false
    @State private var didChange = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 32) {
            VStack(spacing: 12) {
                Text(title)
                    .font(.title2.bold())
                Text(message ?? " ")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            PINEntryView(pin: $pin, isEnabled: !isWorking, failureCount: failureCount, onComplete: submit)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Cambia PIN")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sensoryFeedback(.success, trigger: didChange)
        .alert("PIN cambiato", isPresented: $didChange) {
            Button("OK") { dismiss() }
        }
    }

    private var title: String {
        switch step {
        case .current: "Inserisci il PIN attuale"
        case .new: "Scegli il nuovo PIN"
        case .confirm: "Conferma il nuovo PIN"
        }
    }

    private func submit(_ entered: String) {
        pin = ""
        message = nil
        switch step {
        case .current:
            currentPIN = entered
            step = .new
        case .new:
            newPIN = entered
            step = .confirm
        case .confirm:
            guard entered == newPIN else {
                fail("I PIN non coincidono. Riprova.", restartFrom: .new)
                return
            }
            change()
        }
    }

    private func change() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                switch try await appLock.changePIN(current: currentPIN, new: newPIN) {
                case .success:
                    clearEnteredPINs()
                    didChange = true
                case .wrong(_, let lockedUntil):
                    fail(Self.wrongPINMessage(lockedUntil: lockedUntil), restartFrom: .current)
                case .lockedOut(let lockedUntil):
                    fail(Self.wrongPINMessage(lockedUntil: lockedUntil), restartFrom: .current)
                }
            } catch {
                fail("Operazione non riuscita. Riprova.", restartFrom: .current)
            }
        }
    }

    private func fail(_ text: String, restartFrom restart: Step) {
        if restart == .current {
            clearEnteredPINs()
        } else {
            newPIN = ""
        }
        message = text
        failureCount += 1
        step = restart
    }

    private func clearEnteredPINs() {
        currentPIN = ""
        newPIN = ""
    }

    private static func wrongPINMessage(lockedUntil: Date?) -> String {
        guard let lockedUntil else { return "PIN attuale errato." }
        let minutes = Int((lockedUntil.timeIntervalSinceNow / 60).rounded(.up))
        return minutes <= 1
            ? "PIN errato. Riprova tra 1 minuto."
            : "PIN errato. Riprova tra \(minutes) minuti."
    }
}
