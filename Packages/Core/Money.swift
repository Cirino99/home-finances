import Foundation

public enum MoneyError: Error, Equatable {
    case tooManyDecimals
    case outOfRange
}

/// Conversione tra `Decimal` e unità minori (§ 6.1). Mai `Double`.
///
/// La scala è fissa a 100 per ogni valuta, coerente con il limite di 2 decimali dell'editor (§ 8.5):
/// conta solo che scrittura e lettura usino lo stesso fattore, la formattazione resta quella della valuta.
public enum MinorUnits {
    public static let perUnit = 100

    public static func from(_ value: Decimal) throws -> Int64 {
        var scaled = value * Decimal(perUnit)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else { throw MoneyError.tooManyDecimals }
        guard rounded >= Decimal(Int64.min), rounded <= Decimal(Int64.max) else { throw MoneyError.outOfRange }
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    public static func decimal(_ minorUnits: Int64) -> Decimal {
        Decimal(minorUnits) / Decimal(perUnit)
    }
}

/// Formattazione degli importi con la `Locale` dell'utente (§ 6.4).
public enum MoneyFormat {
    /// `signed`: segno sempre esplicito, anche per i positivi.
    public static func string(
        minorUnits: Int64,
        currency: String,
        locale: Locale = .current,
        signed: Bool = false
    ) -> String {
        let style = Decimal.FormatStyle.Currency(code: currency, locale: locale)
        return MinorUnits.decimal(minorUnits)
            .formatted(signed ? style.sign(strategy: .always()) : style)
    }

    /// Importo di un'operazione, con il segno dato dal tipo: su disco è sempre positivo.
    public static func string(
        amount: Int64,
        kind: OperationKind,
        currency: String,
        locale: Locale = .current
    ) -> String {
        string(minorUnits: kind == .income ? amount : -amount, currency: currency, locale: locale, signed: true)
    }
}
