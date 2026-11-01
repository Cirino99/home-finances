import Foundation
import LocalAuthentication
import Security

public enum BiometryKind: Sendable, Equatable {
    case unavailable
    case touchID
    case faceID
    case opticID
}

public extension BiometryKind {
    var displayName: String {
        switch self {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        case .unavailable: "Biometria"
        }
    }

    var symbolName: String {
        switch self {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .unavailable: "lock"
        }
    }
}

public enum BiometricTokenResult: Sendable, Equatable {
    case valid
    /// Il token non c'è più: il sistema lo cancella quando cambiano i volti o le impronte registrati.
    case invalidated
}

/// Accesso a Face ID / Touch ID e al codice del dispositivo, astratto per i test.
///
/// Lo sblocco legge un token dal Keychain protetto dalla biometria, invece di fidarsi del solo esito di
/// `evaluatePolicy`: è il Secure Enclave a decidere, e lo stesso meccanismo potrà custodire la chiave di cifratura.
public protocol BiometricAuthenticator: Sendable {
    /// Biometria disponibile e configurata in questo momento.
    func availableBiometry() -> BiometryKind
    /// Crea il token legato alle biometrie registrate ora, sostituendo quello precedente.
    func createUnlockToken() async throws
    /// Chiede la biometria e legge il token. Lancia un errore se è annullata o non riconosciuta.
    func readUnlockToken(reason: String) async throws -> BiometricTokenResult
    func removeUnlockToken() throws
    /// Biometria o codice del dispositivo: dimostra di essere il proprietario (§ 5.5).
    func authenticateDeviceOwner(reason: String) async throws
}

public struct SystemBiometricAuthenticator: BiometricAuthenticator {
    private let service: String

    /// `service`: gruppo delle voci nel Keychain.
    public init(service: String) {
        self.service = service
    }

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

    @concurrent
    public func createUnlockToken() async throws {
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,
            &error
        ) else {
            if let error {
                throw error.takeRetainedValue()
            }
            throw BiometricError.unavailable
        }

        try removeUnlockToken()
        var query = baseQuery
        query[kSecAttrAccessControl as String] = accessControl
        query[kSecValueData as String] = try PINHasher.randomBytes(count: 32)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// `@concurrent` perché la lettura resta bloccata finché l'utente non risponde al prompt.
    @concurrent
    public func readUnlockToken(reason: String) async throws -> BiometricTokenResult {
        let context = LAContext()
        context.localizedReason = reason
        context.localizedFallbackTitle = String(localized: "Usa il PIN")

        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return .valid
        case errSecItemNotFound:
            return .invalidated
        default:
            throw KeychainError(status: status)
        }
    }

    public func removeUnlockToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    public func authenticateDeviceOwner(reason: String) async throws {
        let context = LAContext()
        _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "biometric-unlock-token",
            kSecUseDataProtectionKeychain as String: true,
        ]
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
        try store.data(for: .biometricEnabled) != nil
    }

    /// Crea il token e chiede subito la biometria: se l'utente annulla, resta tutto disattivato.
    func enable(reason: String) async throws {
        try await authenticator.createUnlockToken()
        guard try await authenticator.readUnlockToken(reason: reason) == .valid else {
            throw BiometricError.unavailable
        }
        try store.set(Data([1]), for: .biometricEnabled)
    }

    func disable() throws {
        try authenticator.removeUnlockToken()
        try store.remove(.biometricEnabled)
    }

    func unlock(reason: String) async throws -> BiometricUnlockResult {
        guard try isEnabled() else { return .notEnabled }
        guard authenticator.availableBiometry() != .unavailable else { return .unavailable }
        guard try await authenticator.readUnlockToken(reason: reason) == .valid else {
            try disable()
            return .biometryChanged
        }
        return .success
    }
}
