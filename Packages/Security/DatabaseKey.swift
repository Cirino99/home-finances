import CryptoKit
import Foundation

/// Chiave del database (§ 5.7): 256 bit casuali, generati una volta e mai cambiati in v1.
/// Cambiare il PIN la avvolge di nuovo, senza ricifrare il database.
public struct DatabaseKey: Sendable, Equatable, CustomStringConvertible {
    public static let byteCount = 32

    let rawValue: Data

    init?(rawValue: Data) {
        guard rawValue.count == Self.byteCount else { return nil }
        self.rawValue = rawValue
    }

    static func generate() throws -> DatabaseKey {
        // Valido per costruzione: la lunghezza è quella giusta.
        DatabaseKey(rawValue: try PINHasher.randomBytes(count: byteCount))!
    }

    /// Chiave grezza nel formato di SQLCipher, `x'…'`: niente derivazione da password a ogni apertura.
    public var sqlCipherKey: String {
        "x'" + rawValue.map { String(format: "%02x", $0) }.joined() + "'"
    }

    /// Mai il contenuto: la chiave non deve finire nei log.
    public var description: String {
        "DatabaseKey(…)"
    }
}

public enum DatabaseKeyError: Error, Equatable {
    /// La chiave del dispositivo manca o non apre i dati: non è un PIN sbagliato, è un Keychain incompleto.
    case deviceKeyUnavailable
    /// I dati salvati non hanno il formato atteso.
    case corrupted
}

// MARK: Livello del dispositivo

/// Avvolge dati con una chiave che non lascia il dispositivo (§ 5.7). Così la chiave del database
/// avvolta dal solo PIN, di 6 cifre, non si può attaccare per tentativi fuori dal dispositivo.
public protocol DeviceKeyWrapper: Sendable {
    func wrap(_ data: Data) throws -> Data
    /// Lancia `DatabaseKeyError.deviceKeyUnavailable` se la chiave del dispositivo manca o non corrisponde.
    func unwrap(_ data: Data) throws -> Data
    /// Cancella la chiave del dispositivo: quanto avvolto finora non si potrà più aprire.
    func reset() throws
}

/// Chiave P-256 del Secure Enclave, con avvolgimento ECIES: accordo di chiave con una chiave effimera,
/// HKDF-SHA256 e AES-256-GCM. Nel Keychain c'è solo la rappresentazione cifrata del Secure Enclave,
/// utilizzabile solo da questo dispositivo.
///
/// Dove il Secure Enclave non c'è (per esempio nel simulatore) usa una chiave software nel Keychain,
/// `ThisDeviceOnly`: protegge meno, perché esiste fuori dall'hardware, ma resta legata al dispositivo.
public struct SystemDeviceKeyWrapper: DeviceKeyWrapper {
    private let store: any SecureStore

    public init(store: any SecureStore) {
        self.store = store
    }

    public func wrap(_ data: Data) throws -> Data {
        try ECIES.seal(data, to: deviceKey(createIfMissing: true).publicKey)
    }

    public func unwrap(_ data: Data) throws -> Data {
        try ECIES.open(data, with: deviceKey(createIfMissing: false))
    }

    public func reset() throws {
        try store.remove(.deviceWrappingKey)
    }

    private func deviceKey(createIfMissing: Bool) throws -> any ECIESPrivateKey {
        if let stored = try store.data(for: .deviceWrappingKey) {
            return try StoredDeviceKey.decode(stored)
        }
        guard createIfMissing else { throw DatabaseKeyError.deviceKeyUnavailable }
        let key: any ECIESPrivateKey = SecureEnclave.isAvailable
            ? try SecureEnclave.P256.KeyAgreement.PrivateKey()
            : P256.KeyAgreement.PrivateKey()
        try store.set(StoredDeviceKey.encode(key), for: .deviceWrappingKey)
        return key
    }
}

/// Chiave privata usabile per ECIES: quella del Secure Enclave o quella software.
protocol ECIESPrivateKey {
    var publicKey: P256.KeyAgreement.PublicKey { get }
    func sharedSecretFromKeyAgreement(with publicKeyShare: P256.KeyAgreement.PublicKey) throws -> SharedSecret
}

extension SecureEnclave.P256.KeyAgreement.PrivateKey: ECIESPrivateKey {}
extension P256.KeyAgreement.PrivateKey: ECIESPrivateKey {}

/// Formato nel Keychain: un byte per il tipo, poi la rappresentazione della chiave.
private enum StoredDeviceKey {
    static let secureEnclave: UInt8 = 1
    static let software: UInt8 = 2

    static func encode(_ key: any ECIESPrivateKey) throws -> Data {
        switch key {
        case let key as SecureEnclave.P256.KeyAgreement.PrivateKey:
            Data([secureEnclave]) + key.dataRepresentation
        case let key as P256.KeyAgreement.PrivateKey:
            Data([software]) + key.rawRepresentation
        default:
            throw DatabaseKeyError.corrupted
        }
    }

    static func decode(_ data: Data) throws -> any ECIESPrivateKey {
        guard let kind = data.first else { throw DatabaseKeyError.corrupted }
        let body = Data(data.dropFirst())
        do {
            switch kind {
            case secureEnclave: return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: body)
            case software: return try P256.KeyAgreement.PrivateKey(rawRepresentation: body)
            default: throw DatabaseKeyError.corrupted
            }
        } catch let error as DatabaseKeyError {
            throw error
        } catch {
            // Per esempio una chiave del Secure Enclave di un altro dispositivo.
            throw DatabaseKeyError.deviceKeyUnavailable
        }
    }
}

/// `chiave pubblica effimera (65 byte, X9.63) | nonce + dati cifrati + tag`.
enum ECIES {
    private static let ephemeralKeyLength = 65
    private static let info = Data("HomeFinances device key wrap v1".utf8)

    static func seal(_ data: Data, to recipient: P256.KeyAgreement.PublicKey) throws -> Data {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let key = try symmetricKey(
            secret: ephemeral.sharedSecretFromKeyAgreement(with: recipient),
            ephemeral: ephemeral.publicKey,
            recipient: recipient
        )
        guard let sealed = try AES.GCM.seal(data, using: key).combined else { throw DatabaseKeyError.corrupted }
        return ephemeral.publicKey.x963Representation + sealed
    }

    static func open(_ data: Data, with privateKey: any ECIESPrivateKey) throws -> Data {
        guard data.count > ephemeralKeyLength else { throw DatabaseKeyError.corrupted }
        let ephemeral: P256.KeyAgreement.PublicKey
        let box: AES.GCM.SealedBox
        do {
            ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: data.prefix(ephemeralKeyLength))
            box = try AES.GCM.SealedBox(combined: Data(data.dropFirst(ephemeralKeyLength)))
        } catch {
            throw DatabaseKeyError.corrupted
        }
        do {
            let key = try symmetricKey(
                secret: privateKey.sharedSecretFromKeyAgreement(with: ephemeral),
                ephemeral: ephemeral,
                recipient: privateKey.publicKey
            )
            return try AES.GCM.open(box, using: key)
        } catch {
            // Chiave del dispositivo diversa da quella usata per avvolgere.
            throw DatabaseKeyError.deviceKeyUnavailable
        }
    }

    private static func symmetricKey(
        secret: SharedSecret,
        ephemeral: P256.KeyAgreement.PublicKey,
        recipient: P256.KeyAgreement.PublicKey
    ) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeral.x963Representation + recipient.x963Representation,
            sharedInfo: info,
            outputByteCount: 32
        )
    }
}

// MARK: Livello del PIN

/// Chiave del database avvolta dal PIN: AES-256-GCM con una chiave derivata con PBKDF2 (§ 5.7).
/// Nel Keychain finisce a sua volta avvolta dalla chiave del dispositivo.
struct PINWrappedKey: Codable, Sendable, Equatable {
    var salt: Data
    /// Salvate per poterle aumentare in futuro, come per l'hash di prima.
    var iterations: Int
    /// Nonce, chiave cifrata e tag.
    var sealed: Data

    static func wrap(_ key: DatabaseKey, pin: String, iterations: Int) throws -> PINWrappedKey {
        let salt = try PINHasher.randomBytes(count: PINHasher.saltLength)
        let kek = try PINHasher.derive(pin: pin, salt: salt, iterations: iterations)
        guard let sealed = try AES.GCM.seal(key.rawValue, using: SymmetricKey(data: kek)).combined else {
            throw DatabaseKeyError.corrupted
        }
        return PINWrappedKey(salt: salt, iterations: iterations, sealed: sealed)
    }

    /// `nil` se il PIN è sbagliato: il tag di AES-GCM non torna.
    func unwrap(pin: String) throws -> DatabaseKey? {
        let kek = try PINHasher.derive(pin: pin, salt: salt, iterations: iterations)
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: sealed)
        } catch {
            throw DatabaseKeyError.corrupted
        }
        guard let raw = try? AES.GCM.open(box, using: SymmetricKey(data: kek)) else { return nil }
        guard let key = DatabaseKey(rawValue: raw) else { throw DatabaseKeyError.corrupted }
        return key
    }
}

// MARK: Copia per la biometria

/// Contenuto della voce biometrica del Keychain: la chiave del database avvolta dal dispositivo,
/// preceduta da un'intestazione. Il vecchio token casuale non ce l'ha (§ 5.3).
enum BiometricSecret {
    private static let magic = Data("HFDK1".utf8)

    static func make(_ key: DatabaseKey, wrapper: any DeviceKeyWrapper) throws -> Data {
        try magic + wrapper.wrap(key.rawValue)
    }

    /// `nil` per il vecchio token, che sblocca l'app ma non contiene la chiave.
    static func key(from secret: Data, wrapper: any DeviceKeyWrapper) throws -> DatabaseKey? {
        guard secret.starts(with: magic) else { return nil }
        let raw = try wrapper.unwrap(Data(secret.dropFirst(magic.count)))
        guard let key = DatabaseKey(rawValue: raw) else { throw DatabaseKeyError.corrupted }
        return key
    }
}
