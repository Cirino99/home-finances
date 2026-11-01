import Darwin
import Foundation

/// Esito della verifica di un PIN.
public enum PINVerification: Equatable, Sendable {
    case success
    /// PIN errato; `lockedUntil` è valorizzato se scatta un'attesa.
    case wrong(failedAttempts: Int, lockedUntil: Date?)
    /// Attesa in corso: il PIN non è stato nemmeno controllato.
    case lockedOut(until: Date)
}

public enum PasscodeError: Error, Equatable {
    case invalidFormat
    case notSet
}

/// Le due misure del tempo usate dalle attese.
public struct SecurityClock: Sendable {
    /// Ora mostrata all'utente. Modificabile da chiunque abbia il dispositivo in mano.
    public var now: @Sendable () -> Date
    /// Secondi dall'avvio del dispositivo, anche durante lo stop. Riparte da zero al riavvio
    /// e non si può modificare: è ciò che misura davvero le attese.
    public var uptime: @Sendable () -> TimeInterval

    public init(now: @escaping @Sendable () -> Date, uptime: @escaping @Sendable () -> TimeInterval) {
        self.now = now
        self.uptime = uptime
    }

    public static let system = SecurityClock(
        now: { Date() },
        uptime: { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000 }
    )
}

/// Tentativi errati e attesa in corso.
struct LockoutState: Codable, Sendable, Equatable {
    struct Wait: Codable, Sendable, Equatable {
        var duration: TimeInterval
        var startedAtUptime: TimeInterval
    }

    var failedAttempts = 0
    var wait: Wait?
}

/// Attese dopo i tentativi errati (§ 5.2). Nessuna cancellazione dei dati in v1.
public enum LockoutPolicy {
    public static func delay(afterFailedAttempts attempts: Int) -> TimeInterval? {
        switch attempts {
        case ..<5: nil
        case 5: 60
        case 6: 5 * 60
        case 7: 15 * 60
        default: 60 * 60
        }
    }
}

/// Impostazione, verifica e cambio del PIN.
///
/// I metodi con il calcolo dell'hash sono `@concurrent`: con 600.000 iterazioni richiede
/// qualche decimo di secondo e non deve bloccare l'interfaccia.
public struct PasscodeService: Sendable {
    public static let pinLength = 6
    public static let defaultIterations = 600_000

    private let store: any SecureStore
    private let iterations: Int
    private let clock: SecurityClock

    public init(
        store: any SecureStore,
        iterations: Int = PasscodeService.defaultIterations,
        clock: SecurityClock = .system
    ) {
        self.store = store
        self.iterations = iterations
        self.clock = clock
    }

    /// Esattamente 6 cifre ASCII (niente cifre di altri alfabeti, che il tastierino non può produrre).
    public static func isValidPIN(_ pin: String) -> Bool {
        pin.utf8.count == pinLength && pin.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    public func hasPIN() throws -> Bool {
        try store.data(for: .pinCredential) != nil
    }

    /// Salva un nuovo salt e il nuovo hash, e azzera i tentativi.
    @concurrent
    public func setPIN(_ pin: String) async throws {
        guard Self.isValidPIN(pin) else { throw PasscodeError.invalidFormat }
        let credential = try PINHasher.makeCredential(pin: pin, iterations: iterations)
        try store.save(credential, for: .pinCredential)
        try resetLockout()
    }

    @concurrent
    public func verify(_ pin: String) async throws -> PINVerification {
        guard let credential = try store.load(PINCredential.self, for: .pinCredential) else {
            throw PasscodeError.notSet
        }
        var state = try lockoutState()
        if let lockedUntil = try currentLockedUntil(&state) {
            return .lockedOut(until: lockedUntil)
        }

        // Il tentativo si conta prima del confronto: chiudere l'app durante il calcolo non lo annulla.
        state.failedAttempts += 1
        state.wait = LockoutPolicy.delay(afterFailedAttempts: state.failedAttempts).map {
            LockoutState.Wait(duration: $0, startedAtUptime: clock.uptime())
        }
        try store.save(state, for: .lockoutState)

        let candidate = try PINHasher.derive(pin: pin, salt: credential.salt, iterations: credential.iterations)
        guard PINHasher.constantTimeEquals(candidate, credential.hash) else {
            return .wrong(failedAttempts: state.failedAttempts, lockedUntil: try currentLockedUntil(&state))
        }

        try resetLockout()
        if credential.iterations < iterations {
            // Hash calcolato con meno iterazioni di quelle attuali: si aggiorna ora che il PIN è noto.
            try? store.save(PINHasher.makeCredential(pin: pin, iterations: iterations), for: .pinCredential)
        }
        return .success
    }

    /// Verifica il PIN attuale e, se corretto, lo sostituisce. Il PIN errato conta come tentativo fallito.
    @concurrent
    public func changePIN(current: String, new: String) async throws -> PINVerification {
        guard Self.isValidPIN(new) else { throw PasscodeError.invalidFormat }
        let result = try await verify(current)
        if result == .success {
            try await setPIN(new)
        }
        return result
    }

    /// Fine dell'attesa in corso, da mostrare all'utente; `nil` se non c'è.
    func lockedUntil() throws -> Date? {
        var state = try lockoutState()
        return try currentLockedUntil(&state)
    }

    func lockoutState() throws -> LockoutState {
        try store.load(LockoutState.self, for: .lockoutState) ?? LockoutState()
    }

    func resetLockout() throws {
        try store.remove(.lockoutState)
    }

    /// Cancella PIN e tentativi. Solo per chi ha già dimostrato di poterlo fare: vedi `AppLock`.
    func removeCredential() throws {
        try store.remove(.pinCredential)
        try resetLockout()
    }

    /// Calcola il tempo residuo col solo `uptime`: spostare in avanti la data non accorcia l'attesa.
    /// Dopo un riavvio `uptime` riparte da zero: non si sa quanto è passato, quindi l'attesa ricomincia.
    private func currentLockedUntil(_ state: inout LockoutState) throws -> Date? {
        guard var wait = state.wait else { return nil }
        let uptime = clock.uptime()
        if uptime < wait.startedAtUptime {
            wait.startedAtUptime = uptime
            state.wait = wait
            try store.save(state, for: .lockoutState)
        }
        let remaining = wait.duration - (uptime - wait.startedAtUptime)
        return remaining > 0 ? clock.now().addingTimeInterval(remaining) : nil
    }
}
