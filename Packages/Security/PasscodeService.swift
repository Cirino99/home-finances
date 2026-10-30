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

/// Tentativi errati e fine dell'eventuale attesa.
struct LockoutState: Codable, Sendable, Equatable {
    var failedAttempts = 0
    var lockedUntil: Date?
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
/// I metodi `async` girano fuori dal main actor: con 600.000 iterazioni il calcolo dell'hash richiede qualche decimo di secondo.
public struct PasscodeService: Sendable {
    public static let pinLength = 6
    public static let defaultIterations = 600_000

    private let store: any SecureStore
    private let iterations: Int
    private let now: @Sendable () -> Date

    public init(
        store: any SecureStore,
        iterations: Int = PasscodeService.defaultIterations,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.iterations = iterations
        self.now = now
    }

    /// Esattamente 6 cifre ASCII (niente cifre di altri alfabeti, che il tastierino non può produrre).
    public static func isValidPIN(_ pin: String) -> Bool {
        pin.utf8.count == pinLength && pin.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    public func hasPIN() throws -> Bool {
        try store.data(for: .pinCredential) != nil
    }

    /// Salva un nuovo salt e il nuovo hash, e azzera i tentativi.
    public func setPIN(_ pin: String) async throws {
        guard Self.isValidPIN(pin) else { throw PasscodeError.invalidFormat }
        let credential = try PINHasher.makeCredential(pin: pin, iterations: iterations)
        try store.save(credential, for: .pinCredential)
        try resetLockout()
    }

    public func verify(_ pin: String) async throws -> PINVerification {
        guard let credential = try store.load(PINCredential.self, for: .pinCredential) else {
            throw PasscodeError.notSet
        }
        var state = try lockoutState()
        let date = now()
        if let lockedUntil = state.lockedUntil, lockedUntil > date {
            return .lockedOut(until: lockedUntil)
        }

        // Il tentativo si conta prima del confronto: chiudere l'app durante il calcolo non lo annulla.
        state.failedAttempts += 1
        state.lockedUntil = LockoutPolicy.delay(afterFailedAttempts: state.failedAttempts).map(date.addingTimeInterval)
        try store.save(state, for: .lockoutState)

        let candidate = try PINHasher.derive(pin: pin, salt: credential.salt, iterations: credential.iterations)
        guard PINHasher.constantTimeEquals(candidate, credential.hash) else {
            return .wrong(failedAttempts: state.failedAttempts, lockedUntil: state.lockedUntil)
        }

        try resetLockout()
        if credential.iterations < iterations {
            // Hash calcolato con meno iterazioni di quelle attuali: si aggiorna ora che il PIN è noto.
            try? store.save(PINHasher.makeCredential(pin: pin, iterations: iterations), for: .pinCredential)
        }
        return .success
    }

    /// Verifica il PIN attuale e, se corretto, lo sostituisce. Il PIN errato conta come tentativo fallito.
    public func changePIN(current: String, new: String) async throws -> PINVerification {
        guard Self.isValidPIN(new) else { throw PasscodeError.invalidFormat }
        let result = try await verify(current)
        if result == .success {
            try await setPIN(new)
        }
        return result
    }

    func lockoutState() throws -> LockoutState {
        try store.load(LockoutState.self, for: .lockoutState) ?? LockoutState()
    }

    func resetLockout() throws {
        try store.remove(.lockoutState)
    }
}
