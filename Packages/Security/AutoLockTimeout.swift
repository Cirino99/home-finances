/// Blocco per inattività su Mac (§ 5.4). È una preferenza locale: non finisce nell'export del database.
public enum AutoLockTimeout: Int, CaseIterable, Sendable {
    case oneMinute = 1
    case fiveMinutes = 5
    case fifteenMinutes = 15
    case thirtyMinutes = 30

    public static let `default` = AutoLockTimeout.fiveMinutes
    /// Chiave in `UserDefaults`.
    public static let storageKey = "autoLockTimeout"

    public var duration: Duration {
        .seconds(rawValue * 60)
    }
}
