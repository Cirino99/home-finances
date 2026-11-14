import CryptoKit
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
        /// Contenuto della voce biometrica; `nil` se non c'è.
        var secret: Data?
        var succeeds = true
        var biometricPrompts = 0
        var deviceOwnerPrompts = 0
    }

    let state = Mutex(State())

    func availableBiometry() -> BiometryKind {
        state.withLock { $0.biometry }
    }

    var hasToken: Bool {
        state.withLock { $0.secret != nil }
    }

    func storeUnlockSecret(_ secret: Data) async throws {
        state.withLock { $0.secret = secret }
    }

    func readUnlockSecret(reason: String) async throws -> BiometricSecretResult {
        // Come il Keychain: senza la voce non compare nessun prompt.
        guard let secret = state.withLock({ $0.secret }) else { return .invalidated }
        let succeeds = state.withLock {
            $0.biometricPrompts += 1
            return $0.succeeds
        }
        if !succeeds { throw AuthenticationFailed() }
        return .secret(secret)
    }

    func removeUnlockSecret() throws {
        state.withLock { $0.secret = nil }
    }

    /// Il sistema cancella la voce quando cambiano i volti o le impronte registrati.
    func changeEnrolledBiometrics() {
        state.withLock { $0.secret = nil }
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

/// Livello del dispositivo simulato: AES-GCM con una chiave in memoria al posto del Secure Enclave.
/// `reset()` la sostituisce, come la perdita della chiave del dispositivo.
final class FakeDeviceKeyWrapper: DeviceKeyWrapper {
    private let key = Mutex(SymmetricKey(size: .bits256))
    private let wraps = Mutex(0)

    var wrapCount: Int { wraps.withLock { $0 } }

    func wrap(_ data: Data) throws -> Data {
        wraps.withLock { $0 += 1 }
        return try AES.GCM.seal(data, using: key.withLock { $0 }).combined!
    }

    func unwrap(_ data: Data) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key.withLock { $0 })
        } catch {
            throw DatabaseKeyError.deviceKeyUnavailable
        }
    }

    func reset() throws {
        key.withLock { $0 = SymmetricKey(size: .bits256) }
    }
}
