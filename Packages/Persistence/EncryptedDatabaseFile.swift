import CommonCrypto
import Core
import CryptoKit
import Foundation
import Security

/// File di export protetto da password (§ 10.2): AES-256-GCM, con la chiave derivata dalla password.
///
/// Formato: `magic (8) | iterazioni (4, big endian) | salt (16) | nonce + dati cifrati + tag`.
/// L'intestazione è autenticata: non si può modificare senza che la decifratura fallisca.
enum EncryptedDatabaseFile {
    /// PBKDF2-HMAC-SHA256. La password protegge un file che può girare ovunque e ricevere
    /// tentativi senza limiti: più iterazioni del PIN, che ha le attese a difenderlo.
    static let defaultIterations: UInt32 = 1_000_000
    /// Le iterazioni le dichiara il file, che non è attendibile: senza limite potrebbe bloccare l'app.
    private static let maxIterations: UInt32 = 10_000_000

    private static let magic = Data("HFENCDB1".utf8)
    private static let saltLength = 16
    private static var headerLength: Int { magic.count + MemoryLayout<UInt32>.size + saltLength }

    static func isEncrypted(_ data: Data) -> Bool {
        data.starts(with: magic)
    }

    static func encrypt(_ plaintext: Data, password: String, iterations: UInt32 = defaultIterations) throws -> Data {
        var salt = [UInt8](repeating: 0, count: saltLength)
        guard SecRandomCopyBytes(kSecRandomDefault, saltLength, &salt) == errSecSuccess else {
            throw DataTransferError.databaseUnavailable
        }
        var header = magic
        withUnsafeBytes(of: iterations.bigEndian) { header.append(contentsOf: $0) }
        header.append(contentsOf: salt)

        let key = try deriveKey(password: password, salt: Data(salt), iterations: iterations)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: header)
        guard let combined = sealed.combined else { throw DataTransferError.databaseUnavailable }
        return header + combined
    }

    /// Una password errata e un file manomesso non si distinguono: entrambi falliscono l'autenticazione.
    static func decrypt(_ data: Data, password: String) throws -> Data {
        guard isEncrypted(data), data.count > headerLength else { throw DataTransferError.corruptedData }
        // Base a zero: un `Data` ottenuto da una slice mantiene gli indici originali.
        let bytes = Data(data)
        let header = bytes.prefix(headerLength)
        let iterations = bytes[magic.count..<magic.count + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard (1...maxIterations).contains(iterations) else { throw DataTransferError.corruptedData }
        let salt = bytes[(magic.count + 4)..<headerLength]

        let key = try deriveKey(password: password, salt: Data(salt), iterations: iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: bytes.dropFirst(headerLength))
            return try AES.GCM.open(box, using: key, authenticating: header)
        } catch {
            throw DataTransferError.wrongPassword
        }
    }

    private static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        // Forma Unicode canonica: "è" digitata su due dispositivi può avere byte diversi.
        let password = password.precomposedStringWithCanonicalMapping
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBuffer in
            derived.withUnsafeMutableBufferPointer { output in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password, password.utf8.count,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress, saltBuffer.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    output.baseAddress, output.count
                )
            }
        }
        guard status == Int32(kCCSuccess) else { throw DataTransferError.databaseUnavailable }
        return SymmetricKey(data: derived)
    }
}
