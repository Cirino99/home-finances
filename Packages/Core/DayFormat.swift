import Foundation

/// Testi di date e mesi mostrati nelle schermate (§ 8.2). Sempre nel calendario gregoriano,
/// come le date delle operazioni: "ottobre 2026" deve corrispondere a `2026-10`.
public enum DayFormat {
    /// "Oggi", "Ieri", oppure "12 ott"; con l'anno se diverso da quello di `today`.
    public static func relative(
        _ day: Day,
        today: Day,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let calendar = calendar.gregorianEquivalent
        if day == today { return "Oggi" }
        guard let date = day.date(in: calendar), let todayDate = today.date(in: calendar) else {
            return day.string
        }
        if calendar.dateComponents([.day], from: date, to: todayDate).day == 1 { return "Ieri" }

        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .day()
            .month(.abbreviated)
        if day.year != today.year {
            style = style.year()
        }
        return date.formatted(style)
    }

    /// Intestazione di un gruppo di operazioni: "Oggi", "Ieri", "Lunedì 26 ottobre" (§ 8.3).
    public static func sectionTitle(
        _ day: Day,
        today: Day,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let calendar = calendar.gregorianEquivalent
        if day == today { return "Oggi" }
        guard let date = day.date(in: calendar), let todayDate = today.date(in: calendar) else {
            return day.string
        }
        if calendar.dateComponents([.day], from: date, to: todayDate).day == 1 { return "Ieri" }

        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.wide)
            .day()
            .month(.wide)
        if day.year != today.year {
            style = style.year()
        }
        return capitalizingFirstLetter(date.formatted(style), locale: locale)
    }

    /// "ott", per l'asse dei grafici.
    public static func shortMonth(
        _ month: YearMonth,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let calendar = calendar.gregorianEquivalent
        guard let date = month.firstDay.date(in: calendar) else { return month.string }
        return date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated)
        )
    }

    /// Data per esteso, per il dettaglio di un'operazione (§ 8.4).
    public static func long(_ day: Day, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let calendar = calendar.gregorianEquivalent
        guard let date = day.date(in: calendar) else { return day.string }
        return date.formatted(
            Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        )
    }

    /// "Ottobre 2026".
    public static func monthTitle(
        _ month: YearMonth,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let calendar = calendar.gregorianEquivalent
        guard let date = month.firstDay.date(in: calendar) else { return month.string }
        let text = date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .month(.wide)
                .year()
        )
        return capitalizingFirstLetter(text, locale: locale)
    }

    private static func capitalizingFirstLetter(_ text: String, locale: Locale) -> String {
        text.prefix(1).uppercased(with: locale) + text.dropFirst()
    }
}
