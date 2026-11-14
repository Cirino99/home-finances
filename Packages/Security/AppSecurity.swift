import Foundation
import Observation

/// Stato di blocco dell'app (§ 5.4). Sbloccare dà anche la chiave del database (§ 5.7), che si cancella al blocco.
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
    /// C'è un PIN ma nessun dato da proteggere: si può reimpostare col codice del dispositivo.
    public private(set) var canResetForgottenPIN = false
    /// Overlay di privacy per lo switcher app (iOS/iPadOS, `scenePhase == .inactive`).
    public var isPrivacyCovered = false
    /// Proposta di riattivare la biometria, disattivata perché le biometrie registrate sono cambiate.
    public var offersBiometricReenable = false
    /// Chiave del database, solo ad app sbloccata (§ 5.7). `nil` da bloccata, e anche da sbloccata se si è
    /// entrati con Face ID prima che il PIN creasse la chiave: chi ha già un PIN la ottiene al primo sblocco con il PIN.
    public private(set) var databaseKey: DatabaseKey?

    private let passcode: PasscodeService
    private let biometrics: BiometricLock
    private let authenticator: any BiometricAuthenticator
    private let hasExistingData: () -> Bool
    private var isSetupPINSaved = false
    /// Chiave creata con il PIN dell'onboarding, in attesa di `finishSetup`.
    private var setupKey: DatabaseKey?
    private var biometricPromptedSinceLock = false
    private var biometryChangedSinceUnlock = false

    private static var biometricReason: String {
        String(localized: "Sblocca i tuoi dati finanziari")
    }

    /// `hasExistingData` viene richiamata a ogni controllo: i dati possono comparire durante la sessione.
    public init(
        store: any SecureStore,
        authenticator: any BiometricAuthenticator,
        hasExistingData: @escaping () -> Bool,
        deviceWrapper: (any DeviceKeyWrapper)? = nil,
        pinIterations: Int = PasscodeService.defaultIterations,
        clock: SecurityClock = .system
    ) {
        passcode = PasscodeService(store: store, deviceWrapper: deviceWrapper, iterations: pinIterations, clock: clock)
        biometrics = BiometricLock(store: store, authenticator: authenticator, passcode: passcode)
        self.authenticator = authenticator
        self.hasExistingData = hasExistingData
        load()
    }

    /// Rilegge il Keychain se la lettura precedente era fallita.
    public func reloadIfNeeded() {
        if loadError != nil {
            load()
        }
    }

    /// Da chiamare quando cambia lo stato del database: può cambiare ciò che si deve chiedere.
    public func reload() {
        guard phase != .unlocked, !isSetupPINSaved else { return }
        load()
    }

    private func load() {
        do {
            if try passcode.hasPIN() {
                phase = .locked
                lockedUntil = try passcode.lockedUntil()
                isBiometricUnlockEnabled = try biometrics.isEnabled()
            } else {
                // Se il Keychain non è leggibile si resta bloccati: mai l'onboarding, che permetterebbe di scegliere un nuovo PIN.
                phase = .setup(hasExistingData() ? .restoredData : .firstLaunch)
            }
            biometry = authenticator.availableBiometry()
            loadError = nil
        } catch {
            phase = .locked
            loadError = error
        }
        updateCanResetForgottenPIN()
    }

    private func updateCanResetForgottenPIN() {
        canResetForgottenPIN = phase == .locked && loadError == nil && !hasExistingData()
    }

    // MARK: Blocco e sblocco

    public func lock() {
        guard phase == .unlocked else { return }
        phase = .locked
        databaseKey = nil
        biometricPromptedSinceLock = false
        offersBiometricReenable = false
        updateCanResetForgottenPIN()
    }

    /// Restituisce `nil` se la verifica non è stata eseguita (già in corso, app non bloccata, errore del Keychain).
    @discardableResult
    public func unlock(withPIN pin: String) async -> PINVerification? {
        guard phase == .locked, !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }

        do {
            let unlock = try await passcode.unlock(pin)
            let result = unlock.verification
            switch result {
            case .success:
                if let key = unlock.key {
                    // Non blocca lo sblocco: se fallisce, Face ID resta com'era e si riprova al prossimo PIN.
                    try? await biometrics.replaceLegacyToken(with: key)
                }
                didUnlock(key: unlock.key)
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
            case .success(let key):
                try passcode.resetLockout()
                didUnlock(key: key)
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

    private func didUnlock(key: DatabaseKey?) {
        lockedUntil = nil
        databaseKey = key
        phase = .unlocked
        canResetForgottenPIN = false
        if biometryChangedSinceUnlock {
            biometryChangedSinceUnlock = false
            offersBiometricReenable = biometry != .unavailable
        }
    }

    // MARK: PIN dimenticato

    /// Cancella il PIN, dopo il codice del dispositivo, e riapre l'onboarding. Possibile solo se il database
    /// non contiene dati: su iPhone il Keychain sopravvive alla disinstallazione e senza questa via
    /// un PIN dimenticato renderebbe l'app inutilizzabile. Con dati presenti non si può fare.
    public func resetForgottenPIN() async throws {
        guard phase == .locked, !hasExistingData() else { throw AppLockError.invalidState }
        try await authenticator.authenticateDeviceOwner(reason: String(localized: "Conferma la tua identità per scegliere un nuovo PIN"))
        // Ricontrollato dopo il prompt: nel frattempo lo stato potrebbe essere cambiato.
        guard phase == .locked, !hasExistingData() else { throw AppLockError.invalidState }
        try biometrics.disable()
        try passcode.removeCredential()
        isBiometricUnlockEnabled = false
        lockedUntil = nil
        databaseKey = nil
        biometricPromptedSinceLock = false
        canResetForgottenPIN = false
        phase = .setup(.firstLaunch)
    }

    // MARK: Onboarding

    /// Sul ripristino senza PIN, chiede il codice del dispositivo prima di far scegliere un nuovo PIN (§ 5.5).
    public func authorizeRestore() async throws {
        guard phase == .setup(.restoredData) else { throw AppLockError.invalidState }
        try await authenticator.authenticateDeviceOwner(reason: String(localized: "Conferma la tua identità per proteggere i dati presenti su questo dispositivo"))
        isRestoreAuthorized = true
    }

    public func setInitialPIN(_ pin: String) async throws {
        guard case .setup(let reason) = phase, !isSetupPINSaved else { throw AppLockError.invalidState }
        if reason == .restoredData, !isRestoreAuthorized { throw AppLockError.restoreNotAuthorized }
        // Non si sovrascrive mai un PIN esistente da qui: per cambiarlo serve quello attuale.
        guard try !passcode.hasPIN() else { throw AppLockError.invalidState }
        setupKey = try await passcode.setPIN(pin)
        isSetupPINSaved = true
    }

    public func finishSetup() {
        guard case .setup = phase, isSetupPINSaved else { return }
        // Vale solo durante l'onboarding: dopo, le azioni di sicurezza richiedono l'app sbloccata.
        isSetupPINSaved = false
        databaseKey = setupKey
        setupKey = nil
        phase = .unlocked
    }

    // MARK: Impostazioni di sicurezza

    /// Consentito ad app sbloccata o durante l'onboarding, dopo aver scelto il PIN.
    public func enableBiometricUnlock() async throws {
        guard phase == .unlocked || isSetupPINSaved else { throw AppLockError.invalidState }
        // La voce biometrica contiene la chiave: serve averla, cioè essere entrati con il PIN.
        guard let key = databaseKey ?? setupKey else { throw AppLockError.keyUnavailable }
        try await biometrics.enable(key: key, reason: String(localized: "Attiva lo sblocco dei tuoi dati finanziari"))
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
        let result = try await passcode.changePINReturningKey(current: current, new: new)
        if let key = result.key {
            // Stessa chiave di prima; se la sessione era iniziata con il vecchio token di Face ID, ora c'è.
            databaseKey = key
            try? await biometrics.replaceLegacyToken(with: key)
        }
        return result.verification
    }
}

public enum AppLockError: Error {
    case invalidState
    case restoreNotAuthorized
    /// Serve la chiave del database, che si ottiene sbloccando con il PIN.
    case keyUnavailable
}
