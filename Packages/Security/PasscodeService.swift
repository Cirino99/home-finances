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

/// Esito di un PIN corretto o sbagliato, con la chiave del database quando è corretto.
struct PINUnlock: Sendable, Equatable {
    let verification: PINVerification
    /// `nil` se il PIN è sbagliato o se si è in attesa.
    let key: DatabaseKey?
}

/// Impostazione, verifica e cambio del PIN.
///
/// Il PIN non viene confrontato con un hash: apre la chiave del database, avvolta dal PIN e dal dispositivo
/// (§ 5.7). Se l'apertura riesce il PIN è giusto. Chi ha ancora l'hash di prima della cifratura passa
/// alla chiave avvolta al primo sblocco riuscito.
///
/// I metodi con la derivazione dal PIN sono `@concurrent`: con 600.000 iterazioni richiede
/// qualche decimo di secondo e non deve bloccare l'interfaccia.
public struct PasscodeService: Sendable {
    public static let pinLength = 6
    public static let defaultIterations = 600_000

    private let store: any SecureStore
    private let deviceWrapper: any DeviceKeyWrapper
    private let iterations: Int
    private let clock: SecurityClock

    /// `deviceWrapper`: senza, il Secure Enclave del dispositivo.
    public init(
        store: any SecureStore,
        deviceWrapper: (any DeviceKeyWrapper)? = nil,
        iterations: Int = PasscodeService.defaultIterations,
        clock: SecurityClock = .system
    ) {
        self.store = store
        self.deviceWrapper = deviceWrapper ?? SystemDeviceKeyWrapper(store: store)
        self.iterations = iterations
        self.clock = clock
    }

    /// Esattamente 6 cifre ASCII (niente cifre di altri alfabeti, che il tastierino non può produrre).
    public static func isValidPIN(_ pin: String) -> Bool {
        pin.utf8.count == pinLength && pin.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    public func hasPIN() throws -> Bool {
        try store.data(for: .wrappedDatabaseKey) != nil || store.data(for: .pinCredential) != nil
    }

    /// `true` se il PIN apre già la chiave del database, `false` se c'è ancora l'hash di prima della cifratura.
    func hasWrappedKey() throws -> Bool {
        try store.data(for: .wrappedDatabaseKey) != nil
    }

    /// Avvolge con `pin` la chiave `key`, o una nuova se manca, e azzera i tentativi.
    /// Restituisce la chiave del database.
    @concurrent
    @discardableResult
    public func setPIN(_ pin: String) async throws -> DatabaseKey {
        try await setPIN(pin, keeping: nil)
    }

    @concurrent
    @discardableResult
    func setPIN(_ pin: String, keeping existing: DatabaseKey?) async throws -> DatabaseKey {
        guard Self.isValidPIN(pin) else { throw PasscodeError.invalidFormat }
        let key = try existing ?? DatabaseKey.generate()
        try saveWrapped(key, pin: pin)
        try store.remove(.pinCredential)
        try resetLockout()
        return key
    }

    @concurrent
    public func verify(_ pin: String) async throws -> PINVerification {
        try await unlock(pin).verification
    }

    /// Verifica il PIN e, se è giusto, restituisce la chiave del database.
    @concurrent
    func unlock(_ pin: String) async throws -> PINUnlock {
        let wrapped = try store.data(for: .wrappedDatabaseKey)
        let legacy = try store.load(PINCredential.self, for: .pinCredential)
        guard wrapped != nil || legacy != nil else { throw PasscodeError.notSet }
        // Prima del conteggio: un errore della chiave del dispositivo è un Keychain incompleto,
        // non un PIN sbagliato, e si propaga senza consumare tentativi.
        let pinWrapped = try wrapped.map { try decodePINWrapped(deviceWrapper.unwrap($0)) }

        var state = try lockoutState()
        if let lockedUntil = try currentLockedUntil(&state) {
            return PINUnlock(verification: .lockedOut(until: lockedUntil), key: nil)
        }

        // Il tentativo si conta prima della verifica: chiudere l'app durante il calcolo non lo annulla.
        state.failedAttempts += 1
        state.wait = LockoutPolicy.delay(afterFailedAttempts: state.failedAttempts).map {
            LockoutState.Wait(duration: $0, startedAtUptime: clock.uptime())
        }
        try store.save(state, for: .lockoutState)

        let key: DatabaseKey?
        if let pinWrapped {
            key = try pinWrapped.unwrap(pin: pin)
            if let key, pinWrapped.iterations < iterations {
                // Avvolta con meno iterazioni di quelle attuali: si aggiorna ora che il PIN è noto.
                try? saveWrapped(key, pin: pin)
            }
        } else if let legacy {
            let candidate = try PINHasher.derive(pin: pin, salt: legacy.salt, iterations: legacy.iterations)
            // Prima della cifratura: PIN giusto, quindi si crea la chiave e si toglie l'hash (§ 5.7).
            if PINHasher.constantTimeEquals(candidate, legacy.hash) {
                key = try await setPIN(pin, keeping: nil)
            } else {
                key = nil
            }
        } else {
            key = nil
        }

        guard let key else {
            return PINUnlock(
                verification: .wrong(failedAttempts: state.failedAttempts, lockedUntil: try currentLockedUntil(&state)),
                key: nil
            )
        }
        try resetLockout()
        return PINUnlock(verification: .success, key: key)
    }

    /// Verifica il PIN attuale e, se corretto, avvolge la stessa chiave con quello nuovo:
    /// il database non si ricifra. Il PIN errato conta come tentativo fallito.
    @concurrent
    public func changePIN(current: String, new: String) async throws -> PINVerification {
        try await changePINReturningKey(current: current, new: new).verification
    }

    @concurrent
    func changePINReturningKey(current: String, new: String) async throws -> PINUnlock {
        guard Self.isValidPIN(new) else { throw PasscodeError.invalidFormat }
        let result = try await unlock(current)
        guard let key = result.key else { return result }
        try await setPIN(new, keeping: key)
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

    /// Cancella PIN, chiave avvolta, chiave del dispositivo e tentativi. Solo per chi ha già dimostrato
    /// di poterlo fare: vedi `AppLock`. Dopo, un database cifrato con la vecchia chiave non si apre più.
    func removeCredential() throws {
        try store.remove(.pinCredential)
        try store.remove(.wrappedDatabaseKey)
        try deviceWrapper.reset()
        try resetLockout()
    }

    /// La chiave avvolta dal dispositivo, per la copia biometrica.
    func biometricSecret(for key: DatabaseKey) throws -> Data {
        try BiometricSecret.make(key, wrapper: deviceWrapper)
    }

    /// La chiave contenuta nella copia biometrica; `nil` per il vecchio token.
    func key(fromBiometricSecret secret: Data) throws -> DatabaseKey? {
        try BiometricSecret.key(from: secret, wrapper: deviceWrapper)
    }

    // MARK: Supporto

    private func saveWrapped(_ key: DatabaseKey, pin: String) throws {
        let pinWrapped = try PINWrappedKey.wrap(key, pin: pin, iterations: iterations)
        try store.set(deviceWrapper.wrap(JSONEncoder().encode(pinWrapped)), for: .wrappedDatabaseKey)
    }

    private func decodePINWrapped(_ data: Data) throws -> PINWrappedKey {
        do {
            return try JSONDecoder().decode(PINWrappedKey.self, from: data)
        } catch {
            throw DatabaseKeyError.corrupted
        }
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
