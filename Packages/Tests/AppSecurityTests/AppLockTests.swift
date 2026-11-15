import Foundation
import Testing
@testable import AppSecurity

@MainActor
struct AppLockTests {
    let store = InMemorySecureStore()
    let authenticator = FakeAuthenticator()
    let clock = TestClock()
    let deviceWrapper = FakeDeviceKeyWrapper()

    func makeAppLock(hasExistingData: Bool = false, eraseData: (@MainActor () throws -> Void)? = nil) -> AppLock {
        AppLock(
            store: store,
            authenticator: authenticator,
            hasExistingData: { hasExistingData },
            eraseData: eraseData,
            deviceWrapper: deviceWrapper,
            pinIterations: 1,
            clock: clock.security
        )
    }

    /// Onboarding completo, con o senza biometria.
    func onboard(enableBiometrics: Bool = false) async throws -> AppLock {
        let appLock = makeAppLock()
        try await appLock.setInitialPIN("123456")
        if enableBiometrics {
            try await appLock.enableBiometricUnlock()
        }
        appLock.finishSetup()
        return appLock
    }

    @Test func firstLaunchStartsOnboarding() async throws {
        let appLock = makeAppLock()
        #expect(appLock.phase == .setup(.firstLaunch))

        appLock.finishSetup()
        #expect(appLock.phase == .setup(.firstLaunch), "Senza PIN l'onboarding non si chiude")

        try await appLock.setInitialPIN("123456")
        appLock.finishSetup()
        #expect(appLock.phase == .unlocked)
    }

    @Test func laterLaunchesStartLocked() async throws {
        _ = try await onboard()
        #expect(makeAppLock().phase == .locked)
    }

    @Test func locksAndUnlocksWithPIN() async throws {
        let appLock = try await onboard()
        appLock.lock()
        #expect(appLock.phase == .locked)

        #expect(await appLock.unlock(withPIN: "000000") == .wrong(failedAttempts: 1, lockedUntil: nil))
        #expect(appLock.phase == .locked)
        #expect(await appLock.unlock(withPIN: "123456") == .success)
        #expect(appLock.phase == .unlocked)
    }

    @Test func lockoutIsRestoredAtLaunch() async throws {
        let appLock = try await onboard()
        appLock.lock()
        for _ in 1...5 {
            await appLock.unlock(withPIN: "000000")
        }
        let until = clock.now.addingTimeInterval(60)
        #expect(appLock.lockedUntil == until)
        #expect(makeAppLock().lockedUntil == until)
    }

    @Test func restoredDataRequiresDeviceOwnerBeforeNewPIN() async throws {
        let appLock = makeAppLock(hasExistingData: true)
        #expect(appLock.phase == .setup(.restoredData))

        await #expect(throws: AppLockError.restoreNotAuthorized) {
            try await appLock.setInitialPIN("123456")
        }

        try await appLock.authorizeRestore()
        #expect(authenticator.state.withLock { $0.deviceOwnerPrompts } == 1)
        try await appLock.setInitialPIN("123456")
        appLock.finishSetup()
        #expect(appLock.phase == .unlocked)
    }

    @Test func biometricUnlockResetsFailedAttempts() async throws {
        let appLock = try await onboard(enableBiometrics: true)
        #expect(appLock.isBiometricUnlockEnabled)
        appLock.lock()
        await appLock.unlock(withPIN: "000000")

        await appLock.unlockWithBiometrics()
        #expect(appLock.phase == .unlocked)
        #expect(try PasscodeService(store: store).lockoutState() == LockoutState())
    }

    @Test func cancelledBiometricsKeepAppLocked() async throws {
        let appLock = try await onboard(enableBiometrics: true)
        appLock.lock()
        authenticator.state.withLock { $0.succeeds = false }

        await appLock.unlockWithBiometrics()
        #expect(appLock.phase == .locked)
        #expect(appLock.isBiometricUnlockEnabled)
    }

    @Test func cancellingBiometricsWhileEnablingLeavesThemDisabled() async throws {
        let appLock = makeAppLock()
        try await appLock.setInitialPIN("123456")
        authenticator.state.withLock { $0.succeeds = false }

        await #expect(throws: AuthenticationFailed.self) {
            try await appLock.enableBiometricUnlock()
        }
        #expect(!appLock.isBiometricUnlockEnabled)
    }

    @Test func disablingBiometricsRemovesTheToken() async throws {
        let appLock = try await onboard(enableBiometrics: true)
        try appLock.disableBiometricUnlock()
        #expect(!appLock.isBiometricUnlockEnabled)
        #expect(!authenticator.hasToken)
    }

    // MARK: PIN dimenticato

    @Test func forgottenPINCanBeResetWithoutData() async throws {
        let appLock = try await onboard()
        appLock.lock()
        #expect(appLock.canResetForgottenPIN)

        try await appLock.resetForgottenPIN()

        #expect(authenticator.state.withLock { $0.deviceOwnerPrompts } == 1)
        #expect(appLock.phase == .setup(.firstLaunch))
        try await appLock.setInitialPIN("654321")
        appLock.finishSetup()
        appLock.lock()
        #expect(await appLock.unlock(withPIN: "654321") == .success)
    }

    @Test func biometricsCannotBeEnabledWhileLockedAfterOnboarding() async throws {
        let appLock = try await onboard()
        appLock.lock()
        await #expect(throws: AppLockError.invalidState) {
            try await appLock.enableBiometricUnlock()
        }
    }

    /// Con la cifratura i dati non si possono aprire senza il PIN: reimpostarlo li cancella (§ 5.7).
    @Test func forgottenPINResetWithDataErasesThem() async throws {
        _ = try await onboard()
        let erased = EraseCounter()
        let appLock = makeAppLock(hasExistingData: true) { erased.count += 1 }
        #expect(appLock.phase == .locked)
        #expect(appLock.canResetForgottenPIN)
        #expect(appLock.forgottenPINResetErasesData)

        try await appLock.resetForgottenPIN()

        #expect(erased.count == 1)
        #expect(authenticator.state.withLock { $0.deviceOwnerPrompts } == 1)
        #expect(appLock.phase == .setup(.firstLaunch))
        #expect(!appLock.forgottenPINResetErasesData)
    }

    @Test func forgottenPINResetWithoutDataErasesTheEmptyDatabase() async throws {
        _ = try await onboard()
        let erased = EraseCounter()
        let appLock = makeAppLock { erased.count += 1 }
        #expect(!appLock.forgottenPINResetErasesData)

        try await appLock.resetForgottenPIN()
        #expect(erased.count == 1, "Con la nuova chiave il vecchio database vuoto non si aprirebbe")
    }

    @Test func forgottenPINResetKeepsPINIfErasingFails() async throws {
        _ = try await onboard()
        let appLock = makeAppLock(hasExistingData: true) { throw CocoaError(.fileWriteNoPermission) }

        await #expect(throws: CocoaError.self) {
            try await appLock.resetForgottenPIN()
        }
        #expect(appLock.phase == .locked)
        #expect(await appLock.unlock(withPIN: "123456") == .success)
    }

    @Test func forgottenPINCannotBeResetWithDataAndNoWayToErase() async throws {
        _ = try await onboard()
        let appLock = makeAppLock(hasExistingData: true)

        await #expect(throws: AppLockError.invalidState) {
            try await appLock.resetForgottenPIN()
        }
        #expect(authenticator.state.withLock { $0.deviceOwnerPrompts } == 0)
        #expect(await appLock.unlock(withPIN: "123456") == .success)
    }

    // MARK: Dati che non si aprono

    @Test func unreadableDataIsErasedOnlyUnlockedAndAfterDeviceOwner() async throws {
        _ = try await onboard()
        let erased = EraseCounter()
        let appLock = makeAppLock(hasExistingData: true) { erased.count += 1 }

        await #expect(throws: AppLockError.invalidState) {
            try await appLock.eraseUnreadableData()
        }
        #expect(await appLock.unlock(withPIN: "123456") == .success)

        authenticator.state.withLock { $0.succeeds = false }
        await #expect(throws: AuthenticationFailed.self) {
            try await appLock.eraseUnreadableData()
        }
        #expect(erased.count == 0)

        authenticator.state.withLock { $0.succeeds = true }
        try await appLock.eraseUnreadableData()
        #expect(erased.count == 1)
        #expect(appLock.phase == .unlocked, "La sessione resta: il database rinasce con la sua chiave")
        #expect(appLock.databaseKey != nil)
    }

    @Test func forgottenPINResetRequiresDeviceOwner() async throws {
        let appLock = try await onboard()
        appLock.lock()
        authenticator.state.withLock { $0.succeeds = false }

        await #expect(throws: AuthenticationFailed.self) {
            try await appLock.resetForgottenPIN()
        }
        #expect(appLock.phase == .locked)
        authenticator.state.withLock { $0.succeeds = true }
        #expect(await appLock.unlock(withPIN: "123456") == .success)
    }

    @Test func dataAppearingDuringTheSessionMakesPINResetEraseThem() async throws {
        var hasData = false
        let appLock = AppLock(
            store: store,
            authenticator: authenticator,
            hasExistingData: { hasData },
            pinIterations: 1,
            clock: clock.security
        )
        try await appLock.setInitialPIN("123456")
        appLock.finishSetup()

        hasData = true
        appLock.lock()

        #expect(appLock.canResetForgottenPIN)
        #expect(appLock.forgottenPINResetErasesData)
    }

    @Test func changedBiometryDisablesUnlockAndOffersReenable() async throws {
        let appLock = try await onboard(enableBiometrics: true)
        appLock.lock()
        authenticator.changeEnrolledBiometrics()

        await appLock.unlockWithBiometrics()
        #expect(appLock.phase == .locked)
        #expect(!appLock.isBiometricUnlockEnabled)
        #expect(authenticator.state.withLock { $0.biometricPrompts } == 1, "Nessun prompt dopo il cambio")
        #expect(makeAppLock().isBiometricUnlockEnabled == false)

        await appLock.unlock(withPIN: "123456")
        #expect(appLock.offersBiometricReenable)

        try await appLock.enableBiometricUnlock()
        #expect(appLock.isBiometricUnlockEnabled)
        #expect(!appLock.offersBiometricReenable)
    }

    @Test func automaticBiometricPromptOncePerLock() async throws {
        let appLock = try await onboard(enableBiometrics: true)
        appLock.lock()
        authenticator.state.withLock { $0.succeeds = false }

        await appLock.promptBiometricsIfNeeded()
        await appLock.promptBiometricsIfNeeded()
        #expect(authenticator.state.withLock { $0.biometricPrompts } == 2, "Uno all'attivazione, uno automatico")

        authenticator.state.withLock { $0.succeeds = true }
        await appLock.unlock(withPIN: "123456")
        appLock.lock()
        await appLock.promptBiometricsIfNeeded()
        #expect(appLock.phase == .unlocked)
    }

    @Test func securitySettingsRequireUnlockedApp() async throws {
        let appLock = try await onboard()
        appLock.lock()
        await #expect(throws: AppLockError.invalidState) {
            try await appLock.changePIN(current: "123456", new: "111111")
        }
        #expect(throws: AppLockError.invalidState) {
            try appLock.disableBiometricUnlock()
        }
    }
}

@MainActor
private final class EraseCounter {
    var count = 0
}
