import Foundation
import LocalAuthentication

public enum BiometryKind: Sendable, Equatable {
    case unavailable
    case touchID
    case faceID
    case opticID
}

/// Accesso a Face ID / Touch ID e al codice del dispositivo, astratto per i test.
public protocol BiometricAuthenticator: Sendable {
    /// Biometria disponibile e configurata in questo momento.
    func availableBiometry() -> BiometryKind
    /// Impronta delle biometrie registrate: cambia se si aggiungono o tolgono volti o impronte.
    /// `nil` se la biometria non è utilizzabile adesso.
    func currentDomainState() -> Data?
    func authenticateWithBiometrics(reason: String) async throws
    /// Biometria o codice del dispositivo: usato per il ripristino senza PIN (§ 5.5).
    func authenticateDeviceOwner(reason: String) async throws
}

public struct SystemBiometricAuthenticator: BiometricAuthenticator {
    public init() {}

    public func availableBiometry() -> BiometryKind {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return .unavailable
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .unavailable
        }
    }

    public func currentDomainState() -> Data? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return nil
        }
        return context.domainState.biometry.stateHash
    }

    public func authenticateWithBiometrics(reason: String) async throws {
        let context = LAContext()
        context.localizedFallbackTitle = "Usa il PIN"
        _ = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
    }

    public func authenticateDeviceOwner(reason: String) async throws {
        let context = LAContext()
        _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }
}

public enum BiometricUnlockResult: Sendable, Equatable {
    case success
    /// Le biometrie registrate sono cambiate: lo sblocco biometrico è stato disattivato (§ 5.3).
    case biometryChanged
    case unavailable
    case notEnabled
}

public enum BiometricError: Error {
    case unavailable
}

/// Attivazione e uso dello sblocco biometrico.
struct BiometricLock: Sendable {
    let store: any SecureStore
    let authenticator: any BiometricAuthenticator

    func isEnabled() throws -> Bool {
        try store.data(for: .biometricDomainState) != nil
    }

    /// Chiede la biometria e, se va a buon fine, memorizza lo stato delle biometrie registrate.
    func enable(reason: String) async throws {
        try await authenticator.authenticateWithBiometrics(reason: reason)
        guard let domainState = authenticator.currentDomainState() else {
            throw BiometricError.unavailable
        }
        try store.set(domainState, for: .biometricDomainState)
    }

    func disable() throws {
        try store.remove(.biometricDomainState)
    }

    func unlock(reason: String) async throws -> BiometricUnlockResult {
        guard let savedState = try store.data(for: .biometricDomainState) else { return .notEnabled }
        guard let currentState = authenticator.currentDomainState() else { return .unavailable }
        guard currentState == savedState else {
            try disable()
            return .biometryChanged
        }
        try await authenticator.authenticateWithBiometrics(reason: reason)
        return .success
    }
}
