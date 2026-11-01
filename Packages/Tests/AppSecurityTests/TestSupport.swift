import Foundation
import Synchronization
@testable import AppSecurity

/// Orologio controllato dai test: ora mostrata e tempo dall'avvio si muovono separatamente.
final class TestClock: Sendable {
    private struct State {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        var uptime: TimeInterval = 1000
    }

    private let state = Mutex(State())

    var now: Date { state.withLock { $0.date } }

    var security: SecurityClock {
        SecurityClock(
            now: { [self] in now },
            uptime: { [self] in state.withLock { $0.uptime } }
        )
    }

    /// Passa davvero il tempo.
    func advance(by seconds: TimeInterval) {
        state.withLock {
            $0.date += seconds
            $0.uptime += seconds
        }
    }

    /// L'utente cambia data e ora nelle impostazioni.
    func moveWallClock(by seconds: TimeInterval) {
        state.withLock { $0.date += seconds }
    }

    /// Il dispositivo si riavvia: il tempo dall'avvio riparte da zero.
    func reboot() {
        state.withLock { $0.uptime = 0 }
    }
}

struct AuthenticationFailed: Error {}

/// Biometria simulata.
final class FakeAuthenticator: BiometricAuthenticator {
    struct State {
        var biometry = BiometryKind.faceID
        var hasToken = false
        var succeeds = true
        var biometricPrompts = 0
        var deviceOwnerPrompts = 0
    }

    let state = Mutex(State())

    func availableBiometry() -> BiometryKind {
        state.withLock { $0.biometry }
    }

    func createUnlockToken() async throws {
        state.withLock { $0.hasToken = true }
    }

    func readUnlockToken(reason: String) async throws -> BiometricTokenResult {
        // Come il Keychain: senza il token non compare nessun prompt.
        guard state.withLock({ $0.hasToken }) else { return .invalidated }
        let succeeds = state.withLock {
            $0.biometricPrompts += 1
            return $0.succeeds
        }
        if !succeeds { throw AuthenticationFailed() }
        return .valid
    }

    func removeUnlockToken() throws {
        state.withLock { $0.hasToken = false }
    }

    /// Il sistema cancella il token quando cambiano i volti o le impronte registrati.
    func changeEnrolledBiometrics() {
        state.withLock { $0.hasToken = false }
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
