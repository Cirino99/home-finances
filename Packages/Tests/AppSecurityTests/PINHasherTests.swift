import Foundation
import Testing
@testable import AppSecurity

struct PINHasherTests {
    /// Vettore di prova di PBKDF2-HMAC-SHA256 (RFC 7914 § 11), primi 32 byte.
    @Test func matchesReferenceVector() throws {
        let hash = try PINHasher.derive(pin: "passwd", salt: Data("salt".utf8), iterations: 1)
        #expect(hash == Data(hex: "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc"))
    }

    @Test func credentialsUseRandomSalt() throws {
        let first = try PINHasher.makeCredential(pin: "123456", iterations: 1)
        let second = try PINHasher.makeCredential(pin: "123456", iterations: 1)
        #expect(first.salt.count == PINHasher.saltLength)
        #expect(first.hash.count == PINHasher.hashLength)
        #expect(first.salt != second.salt)
        #expect(first.hash != second.hash)
    }

    @Test func defaultIterationsMeetSpecification() {
        #expect(PasscodeService.defaultIterations >= 600_000)
    }

    @Test func constantTimeComparison() {
        #expect(PINHasher.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 3])))
        #expect(!PINHasher.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 4])))
        #expect(!PINHasher.constantTimeEquals(Data([1, 2, 3]), Data([1, 2])))
    }
}
