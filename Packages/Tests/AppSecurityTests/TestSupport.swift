import Foundation
import Synchronization
@testable import AppSecurity

/// Orologio controllato dai test.
final class TestClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    var now: Date { current.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 += seconds }
    }
}

struct AuthenticationFailed: Error {}

/// Biometria simulata.
final class FakeAuthenticator: BiometricAuthenticator {
    struct State {
        var biometry = BiometryKind.faceID
        var domainState: Data? = Data([1, 2, 3])
        var succeeds = true
        var biometricPrompts = 0
        var deviceOwnerPrompts = 0
    }

    let state = Mutex(State())

    func availableBiometry() -> BiometryKind {
        state.withLock { $0.biometry }
    }

    func currentDomainState() -> Data? {
        state.withLock { $0.domainState }
    }

    func authenticateWithBiometrics(reason: String) async throws {
        let succeeds = state.withLock {
            $0.biometricPrompts += 1
            return $0.succeeds
        }
        if !succeeds { throw AuthenticationFailed() }
    }

    func authenticateDeviceOwner(reason: String) async throws {
        let succeeds = state.withLock {
            $0.deviceOwnerPrompts += 1
            return $0.succeeds
        }
        if !succeeds { throw AuthenticationFailed() }
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
