import CommonCrypto
import Foundation
import Security

/// Ciò che il Keychain conserva del PIN: mai il PIN in chiaro (§ 5.2).
struct PINCredential: Codable, Sendable, Equatable {
    var salt: Data
    var hash: Data
    /// Salvate per poterle aumentare in futuro senza invalidare i PIN esistenti.
    var iterations: Int
}

/// PBKDF2-HMAC-SHA256 tramite CommonCrypto.
enum PINHasher {
    static let saltLength = 16
    static let hashLength = 32

    static func makeCredential(pin: String, iterations: Int) throws -> PINCredential {
        let salt = try randomBytes(count: saltLength)
        let hash = try derive(pin: pin, salt: salt, iterations: iterations)
        return PINCredential(salt: salt, hash: hash, iterations: iterations)
    }

    static func derive(pin: String, salt: Data, iterations: Int) throws -> Data {
        var derived = [UInt8](repeating: 0, count: hashLength)
        let status = salt.withUnsafeBytes { saltBuffer in
            derived.withUnsafeMutableBufferPointer { output in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pin, pin.utf8.count,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress, saltBuffer.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    output.baseAddress, output.count
                )
            }
        }
        guard status == Int32(kCCSuccess) else {
            throw PINHasherError.derivationFailed(status)
        }
        return Data(derived)
    }

    /// Confronto in tempo costante: la durata non rivela quanti byte iniziali coincidono.
    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) {
            difference |= a ^ b
        }
        return difference == 0
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw PINHasherError.randomGenerationFailed(status)
        }
        return Data(bytes)
    }
}

enum PINHasherError: Error {
    case derivationFailed(Int32)
    case randomGenerationFailed(OSStatus)
}
