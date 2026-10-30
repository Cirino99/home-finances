import Foundation
import Testing
@testable import AppSecurity

struct PasscodeServiceTests {
    let store = InMemorySecureStore()
    let clock = TestClock()

    func makeService(iterations: Int = 1) -> PasscodeService {
        PasscodeService(store: store, iterations: iterations) { [clock] in clock.now }
    }

    @Test(arguments: ["12345", "1234567", "12a456", "12 456", "١٢٣٤٥٦", ""])
    func rejectsInvalidPIN(_ pin: String) async {
        await #expect(throws: PasscodeError.invalidFormat) {
            try await makeService().setPIN(pin)
        }
    }

    @Test func pinIsNeverStoredInClear() async throws {
        try await makeService().setPIN("123456")
        let stored = try #require(try store.data(for: .pinCredential))
        #expect(stored.range(of: Data("123456".utf8)) == nil)
    }

    @Test func verifiesCorrectAndWrongPIN() async throws {
        let service = makeService()
        #expect(try !service.hasPIN())
        try await service.setPIN("123456")
        #expect(try service.hasPIN())

        #expect(try await service.verify("123456") == .success)
        #expect(try await service.verify("654321") == .wrong(failedAttempts: 1, lockedUntil: nil))
    }

    @Test func verifyWithoutPINThrows() async {
        await #expect(throws: PasscodeError.notSet) {
            try await makeService().verify("123456")
        }
    }

    @Test(arguments: [
        (1, nil), (4, nil), (5, 60), (6, 300), (7, 900), (8, 3600), (12, 3600),
    ] as [(Int, TimeInterval?)])
    func lockoutPolicy(attempts: Int, delay: TimeInterval?) {
        #expect(LockoutPolicy.delay(afterFailedAttempts: attempts) == delay)
    }

    @Test func waitsGrowAfterRepeatedFailures() async throws {
        let service = makeService()
        try await service.setPIN("123456")

        for attempt in 1...4 {
            #expect(try await service.verify("000000") == .wrong(failedAttempts: attempt, lockedUntil: nil))
        }
        let fifth = clock.now.addingTimeInterval(60)
        #expect(try await service.verify("000000") == .wrong(failedAttempts: 5, lockedUntil: fifth))

        // Durante l'attesa nemmeno il PIN corretto viene controllato.
        #expect(try await service.verify("123456") == .lockedOut(until: fifth))

        clock.advance(by: 60)
        #expect(try await service.verify("000000") == .wrong(failedAttempts: 6, lockedUntil: clock.now.addingTimeInterval(300)))
        clock.advance(by: 300)
        #expect(try await service.verify("000000") == .wrong(failedAttempts: 7, lockedUntil: clock.now.addingTimeInterval(900)))
        clock.advance(by: 900)
        #expect(try await service.verify("000000") == .wrong(failedAttempts: 8, lockedUntil: clock.now.addingTimeInterval(3600)))
        clock.advance(by: 3600)
        #expect(try await service.verify("000000") == .wrong(failedAttempts: 9, lockedUntil: clock.now.addingTimeInterval(3600)))

        clock.advance(by: 3600)
        #expect(try await service.verify("123456") == .success)
        #expect(try service.lockoutState() == LockoutState())
    }

    @Test func failedAttemptsSurviveNewService() async throws {
        try await makeService().setPIN("123456")
        for _ in 1...5 {
            _ = try await makeService().verify("000000")
        }
        #expect(try makeService().lockoutState().failedAttempts == 5)
        #expect(try await makeService().verify("123456") == .lockedOut(until: clock.now.addingTimeInterval(60)))
    }

    @Test func changePINRequiresCurrentPIN() async throws {
        let service = makeService()
        try await service.setPIN("123456")

        #expect(try await service.changePIN(current: "000000", new: "111111") == .wrong(failedAttempts: 1, lockedUntil: nil))
        #expect(try await service.verify("123456") == .success)

        let saltBefore = try #require(try store.load(PINCredential.self, for: .pinCredential)).salt
        #expect(try await service.changePIN(current: "123456", new: "111111") == .success)
        #expect(try store.load(PINCredential.self, for: .pinCredential)?.salt != saltBefore)
        #expect(try await service.verify("123456") == .wrong(failedAttempts: 1, lockedUntil: nil))
        #expect(try await service.verify("111111") == .success)
    }

    @Test func upgradesIterationsAfterSuccessfulVerification() async throws {
        try await makeService(iterations: 1).setPIN("123456")
        #expect(try await makeService(iterations: 2).verify("123456") == .success)
        #expect(try store.load(PINCredential.self, for: .pinCredential)?.iterations == 2)
        #expect(try await makeService(iterations: 2).verify("123456") == .success)
    }
}
