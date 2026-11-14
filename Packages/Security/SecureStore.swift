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

    /// Salt, hash e iterazioni del PIN, prima della cifratura: resta fino al primo sblocco con il PIN.
    static let pinCredential = SecureStoreKey(rawValue: "pin-credential")
    /// Contatore dei tentativi errati e fine dell'attesa: nel Keychain per sopravvivere alla reinstallazione.
    static let lockoutState = SecureStoreKey(rawValue: "lockout-state")
    /// La sua presenza significa "biometria attiva": distingue un token mai creato da uno invalidato dal sistema.
    /// Il nome storico fa sì che chi aveva già attivato la biometria venga invitato a riattivarla.
    static let biometricEnabled = SecureStoreKey(rawValue: "biometric-domain-state")
    /// Chiave del database avvolta dal PIN e poi dal dispositivo (§ 5.7). Sostituisce `pinCredential`.
    static let wrappedDatabaseKey = SecureStoreKey(rawValue: "wrapped-database-key")
    /// Chiave del Secure Enclave, o software dove manca, che avvolge la chiave del database.
    static let deviceWrappingKey = SecureStoreKey(rawValue: "device-wrapping-key")
    /// La copia biometrica contiene la chiave del database e non il vecchio token casuale.
    static let biometricHoldsDatabaseKey = SecureStoreKey(rawValue: "biometric-holds-database-key")
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
