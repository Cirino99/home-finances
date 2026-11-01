import Core
import Foundation
import Testing
@testable import Persistence

struct EncryptedDatabaseFileTests {
    let plaintext = Data("contenuto del database".utf8)

    func encrypted(password: String = "password") throws -> Data {
        try EncryptedDatabaseFile.encrypt(plaintext, password: password, iterations: 1000)
    }

    @Test func roundTrips() throws {
        #expect(try EncryptedDatabaseFile.decrypt(encrypted(), password: "password") == plaintext)
    }

    @Test func recognizesEncryptedFiles() throws {
        #expect(EncryptedDatabaseFile.isEncrypted(try encrypted()))
        #expect(!EncryptedDatabaseFile.isEncrypted(plaintext))
        #expect(!EncryptedDatabaseFile.isEncrypted(Data()))
    }

    @Test func outputIsDifferentEveryTime() throws {
        #expect(try encrypted() != encrypted(), "Salt e nonce sono casuali")
    }

    @Test func doesNotContainThePlaintext() throws {
        #expect(try encrypted().range(of: plaintext) == nil)
    }

    @Test func wrongPasswordFails() throws {
        let file = try encrypted()
        #expect(throws: DataTransferError.wrongPassword) {
            _ = try EncryptedDatabaseFile.decrypt(file, password: "sbagliata")
        }
    }

    /// "è" può essere un carattere solo o "e" più accento: su dispositivi diversi deve valere uguale.
    @Test func passwordIsNormalized() throws {
        let file = try EncryptedDatabaseFile.encrypt(plaintext, password: "caff\u{E8}", iterations: 1000)
        #expect(try EncryptedDatabaseFile.decrypt(file, password: "caffe\u{300}") == plaintext)
    }

    @Test func tamperedContentFails() throws {
        var file = try encrypted()
        file[file.count - 1] ^= 0xFF
        let tampered = file
        #expect(throws: DataTransferError.wrongPassword) {
            _ = try EncryptedDatabaseFile.decrypt(tampered, password: "password")
        }
    }

    /// Il salt è nell'intestazione, autenticata: modificarlo rende il file illeggibile.
    @Test func tamperedHeaderFails() throws {
        var file = try encrypted()
        file[20] ^= 0xFF
        let tampered = file
        #expect(throws: DataTransferError.wrongPassword) {
            _ = try EncryptedDatabaseFile.decrypt(tampered, password: "password")
        }
    }

    /// Un file non deve poter bloccare l'app dichiarando iterazioni enormi.
    @Test(arguments: [UInt32(0), UInt32.max])
    func rejectsUnreasonableIterations(iterations: UInt32) throws {
        var file = try encrypted()
        withUnsafeBytes(of: iterations.bigEndian) { bytes in
            file.replaceSubrange(8..<12, with: bytes)
        }
        let tampered = file
        #expect(throws: DataTransferError.corruptedData) {
            _ = try EncryptedDatabaseFile.decrypt(tampered, password: "password")
        }
    }

    @Test func truncatedFileFails() throws {
        let file = try encrypted().prefix(12)
        #expect(throws: DataTransferError.corruptedData) {
            _ = try EncryptedDatabaseFile.decrypt(Data(file), password: "password")
        }
    }

    @Test func defaultIterationsAreStrong() {
        #expect(EncryptedDatabaseFile.defaultIterations >= 600_000)
    }
}
