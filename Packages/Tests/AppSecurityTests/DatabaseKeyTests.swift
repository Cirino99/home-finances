import CryptoKit
import Foundation
import Testing
@testable import AppSecurity

struct DatabaseKeyTests {
    // MARK: Chiave e livelli

    @Test func keyHasSQLCipherRawFormatAndHidesItsBytes() throws {
        let key = try DatabaseKey.generate()
        #expect(key.rawValue.count == 32)
        #expect(key.sqlCipherKey.hasPrefix("x'"))
        #expect(key.sqlCipherKey.hasSuffix("'"))
        #expect(key.sqlCipherKey.count == 2 + 64 + 1)
        #expect(key.description == "DatabaseKey(…)")
        #expect(try DatabaseKey.generate() != key)
    }

    @Test func pinWrappingOpensOnlyWithTheRightPIN() throws {
        let key = try DatabaseKey.generate()
        let wrapped = try PINWrappedKey.wrap(key, pin: "123456", iterations: 1)
        #expect(try wrapped.unwrap(pin: "123456") == key)
        #expect(try wrapped.unwrap(pin: "123457") == nil)
        #expect(wrapped.sealed.range(of: key.rawValue) == nil)
    }

    @Test func eciesOpensOnlyWithTheSameDeviceKey() throws {
        let deviceKey = P256.KeyAgreement.PrivateKey()
        let sealed = try ECIES.seal(Data("segreto".utf8), to: deviceKey.publicKey)
        #expect(try ECIES.open(sealed, with: deviceKey) == Data("segreto".utf8))

        #expect(throws: DatabaseKeyError.deviceKeyUnavailable) {
            try ECIES.open(sealed, with: P256.KeyAgreement.PrivateKey())
        }
        #expect(throws: DatabaseKeyError.corrupted) {
            try ECIES.open(Data([1, 2, 3]), with: deviceKey)
        }
        // Ogni avvolgimento usa una chiave effimera nuova: mai due risultati uguali.
        #expect(try ECIES.seal(Data("segreto".utf8), to: deviceKey.publicKey) != sealed)
    }

    @Test func biometricSecretCarriesTheKeyAndRecognizesTheLegacyToken() throws {
        let wrapper = FakeDeviceKeyWrapper()
        let key = try DatabaseKey.generate()
        let secret = try BiometricSecret.make(key, wrapper: wrapper)
        #expect(try BiometricSecret.key(from: secret, wrapper: wrapper) == key)
        #expect(secret.range(of: key.rawValue) == nil)

        let legacyToken = try PINHasher.randomBytes(count: 32)
        #expect(try BiometricSecret.key(from: legacyToken, wrapper: wrapper) == nil)
    }
}

struct PasscodeKeyTests {
    let store = InMemorySecureStore()
    let clock = TestClock()
    let deviceWrapper = FakeDeviceKeyWrapper()

    func makeService() -> PasscodeService {
        PasscodeService(store: store, deviceWrapper: deviceWrapper, iterations: 1, clock: clock.security)
    }

    /// Come un'installazione di prima della cifratura: solo l'hash del PIN.
    func storeLegacyPIN(_ pin: String) throws {
        try store.save(PINHasher.makeCredential(pin: pin, iterations: 1), for: .pinCredential)
    }

    @Test func pinOpensTheSameKeyItCreated() async throws {
        let service = makeService()
        let key = try await service.setPIN("123456")

        #expect(try await service.unlock("123456") == PINUnlock(verification: .success, key: key))
        let wrong = try await service.unlock("000000")
        #expect(wrong.key == nil)
        #expect(wrong.verification == .wrong(failedAttempts: 1, lockedUntil: nil))
    }

    @Test func legacyHashBecomesWrappedKeyAtFirstUnlock() async throws {
        try storeLegacyPIN("123456")
        let service = makeService()
        #expect(try service.hasPIN())
        #expect(try !service.hasWrappedKey())

        // PIN sbagliato: niente chiave, e l'hash resta.
        #expect(try await service.unlock("000000").key == nil)
        #expect(try store.data(for: .pinCredential) != nil)

        let key = try #require(try await service.unlock("123456").key)
        #expect(try service.hasWrappedKey())
        #expect(try store.data(for: .pinCredential) == nil, "L'hash non serve più")
        #expect(try service.lockoutState() == LockoutState())
        #expect(try await service.unlock("123456").key == key, "La chiave creata alla conversione resta")
    }

    @Test func lostDeviceKeyIsAnErrorNotAWrongPIN() async throws {
        let service = makeService()
        try await service.setPIN("123456")
        try deviceWrapper.reset()

        await #expect(throws: DatabaseKeyError.deviceKeyUnavailable) {
            try await service.unlock("123456")
        }
        #expect(try service.lockoutState().failedAttempts == 0, "Non consuma tentativi")
    }

    @Test func removingCredentialMakesTheOldKeyUnrecoverable() async throws {
        let service = makeService()
        try await service.setPIN("123456")
        let wrappedBefore = try #require(try store.data(for: .wrappedDatabaseKey))

        try service.removeCredential()
        #expect(try !service.hasPIN())
        #expect(throws: DatabaseKeyError.deviceKeyUnavailable) {
            try deviceWrapper.unwrap(wrappedBefore)
        }
    }

    @Test func changingPINDuringLockoutDoesNothing() async throws {
        let service = makeService()
        let key = try await service.setPIN("123456")
        for _ in 1...5 {
            _ = try await service.unlock("000000")
        }
        let result = try await service.changePINReturningKey(current: "123456", new: "111111")
        guard case .lockedOut = result.verification else {
            Issue.record("Durante l'attesa il PIN non si cambia")
            return
        }
        clock.advance(by: 60)
        #expect(try await service.unlock("123456").key == key)
    }
}

@MainActor
struct AppLockKeyTests {
    let store = InMemorySecureStore()
    let authenticator = FakeAuthenticator()
    let clock = TestClock()
    let deviceWrapper = FakeDeviceKeyWrapper()

    func makeAppLock() -> AppLock {
        AppLock(
            store: store,
            authenticator: authenticator,
            hasExistingData: { false },
            deviceWrapper: deviceWrapper,
            pinIterations: 1,
            clock: clock.security
        )
    }

    @Test func keyIsAvailableOnlyWhileUnlocked() async throws {
        let appLock = makeAppLock()
        try await appLock.setInitialPIN("123456")
        #expect(appLock.databaseKey == nil, "Prima della fine dell'onboarding no")
        try await appLock.enableBiometricUnlock()
        appLock.finishSetup()
        let key = try #require(appLock.databaseKey)

        appLock.lock()
        #expect(appLock.databaseKey == nil, "Al blocco la chiave si cancella")

        await appLock.unlock(withPIN: "123456")
        #expect(appLock.databaseKey == key)

        appLock.lock()
        await appLock.unlockWithBiometrics()
        #expect(appLock.phase == .unlocked)
        #expect(appLock.databaseKey == key, "Face ID dà la stessa chiave del PIN")
    }

    @Test func changingPINKeepsTheKey() async throws {
        let appLock = makeAppLock()
        try await appLock.setInitialPIN("123456")
        appLock.finishSetup()
        let key = try #require(appLock.databaseKey)

        #expect(try await appLock.changePIN(current: "123456", new: "111111") == .success)
        appLock.lock()
        await appLock.unlock(withPIN: "111111")
        #expect(appLock.databaseKey == key)
    }

    /// Installazione di prima della cifratura con Face ID attivo: hash del PIN e token casuale.
    func storeLegacyInstallation() async throws {
        try store.save(PINHasher.makeCredential(pin: "123456", iterations: 1), for: .pinCredential)
        try store.set(Data([1]), for: .biometricEnabled)
        try await authenticator.storeUnlockSecret(PINHasher.randomBytes(count: 32))
    }

    @Test func legacyFaceIDUnlocksWithoutKeyUntilThePINIsUsed() async throws {
        try await storeLegacyInstallation()
        let appLock = makeAppLock()
        #expect(appLock.phase == .locked)

        await appLock.unlockWithBiometrics()
        #expect(appLock.phase == .unlocked)
        #expect(appLock.databaseKey == nil, "Il vecchio token non contiene la chiave")
        await #expect(throws: AppLockError.keyUnavailable) {
            try await appLock.enableBiometricUnlock()
        }

        appLock.lock()
        await appLock.unlock(withPIN: "123456")
        let key = try #require(appLock.databaseKey)
        #expect(try store.data(for: .biometricHoldsDatabaseKey) != nil, "Token sostituito dalla chiave")

        appLock.lock()
        await appLock.unlockWithBiometrics()
        #expect(appLock.databaseKey == key, "Ora Face ID dà la chiave")
    }

    @Test func forgottenPINResetDropsTheKey() async throws {
        let appLock = makeAppLock()
        try await appLock.setInitialPIN("123456")
        appLock.finishSetup()
        appLock.lock()

        try await appLock.resetForgottenPIN()
        #expect(appLock.databaseKey == nil)
        #expect(try store.data(for: .wrappedDatabaseKey) == nil)
        #expect(appLock.phase == .setup(.firstLaunch))
    }
}
