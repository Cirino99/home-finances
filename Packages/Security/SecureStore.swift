import Foundation
import Synchronization

/// Archivio dei piccoli segreti dell'app (§ 5.2): in produzione il Keychain, nei test la memoria.
public protocol SecureStore: Sendable {
    func data(for key: SecureStoreKey) throws -> Data?
    /// Salva `data` sotto `key`; `nil` cancella la voce.
    func set(_ data: Data?, for key: SecureStoreKey) throws
}

public struct SecureStoreKey: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Salt, hash e iterazioni del PIN.
    static let pinCredential = SecureStoreKey(rawValue: "pin-credential")
    /// Contatore dei tentativi errati e fine dell'attesa: nel Keychain per sopravvivere alla reinstallazione.
    static let lockoutState = SecureStoreKey(rawValue: "lockout-state")
    /// Stato delle biometrie registrate all'attivazione; la sua presenza significa "biometria attiva".
    static let biometricDomainState = SecureStoreKey(rawValue: "biometric-domain-state")
}

extension SecureStore {
    func load<Value: Decodable>(_ type: Value.Type, for key: SecureStoreKey) throws -> Value? {
        guard let data = try data(for: key) else { return nil }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func save<Value: Encodable>(_ value: Value, for key: SecureStoreKey) throws {
        try set(JSONEncoder().encode(value), for: key)
    }

    func remove(_ key: SecureStoreKey) throws {
        try set(nil, for: key)
    }
}

/// Archivio in memoria, per test e anteprime.
public final class InMemorySecureStore: SecureStore {
    private let storage = Mutex<[SecureStoreKey: Data]>([:])

    public init() {}

    public func data(for key: SecureStoreKey) throws -> Data? {
        storage.withLock { $0[key] }
    }

    public func set(_ data: Data?, for key: SecureStoreKey) throws {
        storage.withLock { $0[key] = data }
    }
}
