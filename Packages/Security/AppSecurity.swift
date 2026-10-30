import Foundation
import Observation

/// Stato di blocco dell'app (§ 5.4). Il database resta aperto: il blocco agisce sulla UI.
@MainActor
@Observable
public final class AppLock {
    public enum Phase: Equatable, Sendable {
        /// Nessun PIN impostato: onboarding.
        case setup(SetupReason)
        case locked
        case unlocked
    }

    public enum SetupReason: Equatable, Sendable {
        case firstLaunch
        /// Database presente ma nessun PIN, ad esempio dopo un ripristino da backup (§ 5.5).
        case restoredData
    }

    public private(set) var phase: Phase = .locked
    /// Fine dell'attesa dopo troppi tentativi errati.
    public private(set) var lockedUntil: Date?
    public private(set) var biometry: BiometryKind = .unavailable
    public private(set) var isBiometricUnlockEnabled = false
    /// Verifica del PIN o prompt biometrico in corso.
    public private(set) var isBusy = false
    /// Errore nella lettura del Keychain, ad esempio con l'app avviata in background a dispositivo bloccato.
    public private(set) var loadError: (any Error)?
    /// Sul ripristino senza PIN, il codice del dispositivo è stato verificato.
    public private(set) var isRestoreAuthorized = false
    /// Overlay di privacy per lo switcher app (iOS/iPadOS, `scenePhase == .inactive`).
    public var isPrivacyCovered = false
    /// Proposta di riattivare la biometria, disattivata perché le biometrie registrate sono cambiate.
    public var offersBiometricReenable = false

    private let passcode: PasscodeService
    private let biometrics: BiometricLock
    private let authenticator: any BiometricAuthenticator
    private let hasExistingData: Bool
    private var isSetupPINSaved = false
    private var biometricPromptedSinceLock = false
    private var biometryChangedSinceUnlock = false

    private static let biometricReason = "Sblocca i tuoi dati finanziari"

    public init(
        store: any SecureStore,
        authenticator: any BiometricAuthenticator,
        hasExistingData: Bool,
        pinIterations: Int = PasscodeService.defaultIterations,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        passcode = PasscodeService(store: store, iterations: pinIterations, now: now)
        biometrics = BiometricLock(store: store, authenticator: authenticator)
        self.authenticator = authenticator
        self.hasExistingData = hasExistingData
        reload()
    }

    /// Rilegge il Keychain se la lettura precedente era fallita.
    public func reloadIfNeeded() {
        if loadError != nil {
            reload()
        }
    }

    private func reload() {
        do {
            if try passcode.hasPIN() {
                phase = .locked
                lockedUntil = try passcode.lockoutState().lockedUntil
                isBiometricUnlockEnabled = try biometrics.isEnabled()
            } else {
                // Se il Keychain non è leggibile si resta bloccati: mai l'onboarding, che permetterebbe di scegliere un nuovo PIN.
                phase = .setup(hasExistingData ? .restoredData : .firstLaunch)
            }
            biometry = authenticator.availableBiometry()
            loadError = nil
        } catch {
            phase = .locked
            loadError = error
        }
    }

    // MARK: Blocco e sblocco

    public func lock() {
        guard phase == .unlocked else { return }
        phase = .locked
        biometricPromptedSinceLock = false
        offersBiometricReenable = false
    }

    /// Restituisce `nil` se la verifica non è stata eseguita (già in corso, app non bloccata, errore del Keychain).
    @discardableResult
    public func unlock(withPIN pin: String) async -> PINVerification? {
        guard phase == .locked, !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await passcode.verify(pin)
            switch result {
            case .success:
                didUnlock()
            case .wrong(_, let until):
                lockedUntil = until
            case .lockedOut(let until):
                lockedUntil = until
            }
            return result
        } catch {
            loadError = error
            return nil
        }
    }

    public func unlockWithBiometrics() async {
        guard phase == .locked, isBiometricUnlockEnabled, !isBusy else { return }
        biometricPromptedSinceLock = true
        isBusy = true
        defer { isBusy = false }

        do {
            switch try await biometrics.unlock(reason: Self.biometricReason) {
            case .success:
                try passcode.resetLockout()
                didUnlock()
            case .biometryChanged:
                isBiometricUnlockEnabled = false
                biometryChangedSinceUnlock = true
            case .unavailable, .notEnabled:
                break
            }
        } catch {
            // Annullato o non riconosciuto: resta il PIN.
        }
    }

    /// Prompt biometrico automatico, una sola volta per ogni blocco (§ 8.1).
    public func promptBiometricsIfNeeded() async {
        guard !biometricPromptedSinceLock else { return }
        await unlockWithBiometrics()
    }

    private func didUnlock() {
        lockedUntil = nil
        phase = .unlocked
        if biometryChangedSinceUnlock {
            biometryChangedSinceUnlock = false
            offersBiometricReenable = biometry != .unavailable
        }
    }

    // MARK: Onboarding

    /// Sul ripristino senza PIN, chiede il codice del dispositivo prima di far scegliere un nuovo PIN (§ 5.5).
    public func authorizeRestore() async throws {
        guard phase == .setup(.restoredData) else { throw AppLockError.invalidState }
        try await authenticator.authenticateDeviceOwner(reason: "Conferma la tua identità per proteggere i dati presenti su questo dispositivo")
        isRestoreAuthorized = true
    }

    public func setInitialPIN(_ pin: String) async throws {
        guard case .setup(let reason) = phase, !isSetupPINSaved else { throw AppLockError.invalidState }
        if reason == .restoredData, !isRestoreAuthorized { throw AppLockError.restoreNotAuthorized }
        // Non si sovrascrive mai un PIN esistente da qui: per cambiarlo serve quello attuale.
        guard try !passcode.hasPIN() else { throw AppLockError.invalidState }
        try await passcode.setPIN(pin)
        isSetupPINSaved = true
    }

    public func finishSetup() {
        guard case .setup = phase, isSetupPINSaved else { return }
        phase = .unlocked
    }

    // MARK: Impostazioni di sicurezza

    /// Consentito ad app sbloccata o durante l'onboarding, dopo aver scelto il PIN.
    public func enableBiometricUnlock() async throws {
        guard phase == .unlocked || isSetupPINSaved else { throw AppLockError.invalidState }
        try await biometrics.enable(reason: "Attiva lo sblocco dei tuoi dati finanziari")
        isBiometricUnlockEnabled = true
        offersBiometricReenable = false
    }

    public func disableBiometricUnlock() throws {
        guard phase == .unlocked else { throw AppLockError.invalidState }
        try biometrics.disable()
        isBiometricUnlockEnabled = false
    }

    public func changePIN(current: String, new: String) async throws -> PINVerification {
        guard phase == .unlocked else { throw AppLockError.invalidState }
        return try await passcode.changePIN(current: current, new: new)
    }
}

public enum AppLockError: Error {
    case invalidState
    case restoreNotAuthorized
}
