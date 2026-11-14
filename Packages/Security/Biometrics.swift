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

public enum BiometricSecretResult: Sendable, Equatable {
    case secret(Data)
    /// La voce non c'è più: il sistema la cancella quando cambiano i volti o le impronte registrati.
    case invalidated
}

/// Accesso a Face ID / Touch ID e al codice del dispositivo, astratto per i test.
///
/// Lo sblocco legge una voce del Keychain protetta dalla biometria, invece di fidarsi del solo esito di
/// `evaluatePolicy`: è il Secure Enclave a decidere. La voce contiene la chiave del database (§ 5.7).
public protocol BiometricAuthenticator: Sendable {
    /// Biometria disponibile e configurata in questo momento.
    func availableBiometry() -> BiometryKind
    /// Salva `secret` in una voce legata alle biometrie registrate ora, sostituendo quella precedente.
    /// Non chiede la biometria: la scrittura non la richiede.
    func storeUnlockSecret(_ secret: Data) async throws
    /// Chiede la biometria e legge la voce. Lancia un errore se è annullata o non riconosciuta.
    func readUnlockSecret(reason: String) async throws -> BiometricSecretResult
    func removeUnlockSecret() throws
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
    public func storeUnlockSecret(_ secret: Data) async throws {
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

        try removeUnlockSecret()
        var query = baseQuery
        query[kSecAttrAccessControl as String] = accessControl
        query[kSecValueData as String] = secret
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// `@concurrent` perché la lettura resta bloccata finché l'utente non risponde al prompt.
    @concurrent
    public func readUnlockSecret(reason: String) async throws -> BiometricSecretResult {
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
            guard let data = result as? Data else { throw KeychainError(status: errSecDecode) }
            return .secret(data)
        case errSecItemNotFound:
            return .invalidated
        default:
            throw KeychainError(status: status)
        }
    }

    public func removeUnlockSecret() throws {
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
    /// Sbloccato. `key` è la chiave del database; `nil` se la voce è ancora il token di prima della cifratura.
    case success(key: DatabaseKey?)
    /// Le biometrie registrate sono cambiate: lo sblocco biometrico è stato disattivato (§ 5.3).
    case biometryChanged
    case unavailable
    case notEnabled
}

public enum BiometricError: Error {
    case unavailable
}

/// Attivazione e uso dello sblocco biometrico. La voce biometrica contiene la chiave del database
/// avvolta dal dispositivo (§ 5.7): leggerla con Face ID dà la chiave, senza il PIN.
struct BiometricLock: Sendable {
    let store: any SecureStore
    let authenticator: any BiometricAuthenticator
    let passcode: PasscodeService

    func isEnabled() throws -> Bool {
        try store.data(for: .biometricEnabled) != nil
    }

    /// Salva la chiave e chiede subito la biometria: se l'utente annulla, resta tutto disattivato.
    func enable(key: DatabaseKey, reason: String) async throws {
        try await authenticator.storeUnlockSecret(passcode.biometricSecret(for: key))
        guard case .secret(let secret) = try await authenticator.readUnlockSecret(reason: reason),
              try passcode.key(fromBiometricSecret: secret) == key else {
            throw BiometricError.unavailable
        }
        try store.set(Data([1]), for: .biometricEnabled)
        try store.set(Data([1]), for: .biometricHoldsDatabaseKey)
    }

    func disable() throws {
        try authenticator.removeUnlockSecret()
        try store.remove(.biometricEnabled)
        try store.remove(.biometricHoldsDatabaseKey)
    }

    /// Chi aveva attivato la biometria prima della cifratura ha nella voce un token casuale: al primo
    /// sblocco con il PIN lo si sostituisce con la chiave, senza chiedere la biometria (§ 5.7).
    func replaceLegacyToken(with key: DatabaseKey) async throws {
        guard try isEnabled(), try store.data(for: .biometricHoldsDatabaseKey) == nil else { return }
        try await authenticator.storeUnlockSecret(passcode.biometricSecret(for: key))
        try store.set(Data([1]), for: .biometricHoldsDatabaseKey)
    }

    func unlock(reason: String) async throws -> BiometricUnlockResult {
        guard try isEnabled() else { return .notEnabled }
        guard authenticator.availableBiometry() != .unavailable else { return .unavailable }
        guard case .secret(let secret) = try await authenticator.readUnlockSecret(reason: reason) else {
            try disable()
            return .biometryChanged
        }
        return .success(key: try passcode.key(fromBiometricSecret: secret))
    }
}
