import Foundation

public extension Day {
    /// Giorno della settimana come in `Calendar`: 1 = domenica, 7 = sabato. Calendario gregoriano.
    var weekday: Int {
        // Algoritmo di Sakamoto: nessun fuso orario né calendario di sistema in mezzo.
        let offsets = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
        let year = month < 3 ? self.year - 1 : self.year
        let sundayBased = (year + year / 4 - year / 100 + year / 400 + offsets[month - 1] + day) % 7
        return sundayBased + 1
    }

    /// Il giorno `days` giorni dopo (o prima, se negativo), attraversando mesi e anni.
    /// Resta nell'intervallo di `YearMonth`: oltre i limiti si ferma al primo o all'ultimo giorno.
    func adding(days: Int) -> Day {
        var result = self
        var remaining = days
        while remaining > 0 {
            if result.day < result.yearMonth.dayCount {
                result = Day(uncheckedYear: result.year, month: result.month, day: result.day + 1)
            } else if let next = result.yearMonth.next {
                result = next.firstDay
            } else {
                return result
            }
            remaining -= 1
        }
        while remaining < 0 {
            if result.day > 1 {
                result = Day(uncheckedYear: result.year, month: result.month, day: result.day - 1)
            } else if let previous = result.yearMonth.previous {
                result = previous.lastDay
            } else {
                return result
            }
            remaining += 1
        }
        return result
    }

    /// Lo stesso giorno in un altro mese, o l'ultimo se quel mese è più corto (31 → 30, 29 febbraio → 28).
    func moved(to month: YearMonth) -> Day {
        Day(uncheckedYear: month.year, month: month.month, day: min(day, month.dayCount))
    }
}

/// Giorni di un mese divisi per settimana, per il calendario del campo data.
public struct MonthGrid: Equatable, Sendable {
    public let month: YearMonth
    /// Settimane di 7 caselle, dal primo giorno della settimana scelto; `nil` fuori dal mese.
    public let weeks: [[Day?]]

    /// - Parameter firstWeekday: primo giorno della settimana come in `Calendar` (1 = domenica, 2 = lunedì).
    public init(month: YearMonth, firstWeekday: Int) {
        self.month = month
        let first = month.firstDay
        let leading = (first.weekday - firstWeekday + 7) % 7
        var cells: [Day?] = Array(repeating: nil, count: leading)
        for day in 1...month.dayCount {
            cells.append(Day(year: month.year, month: month.month, day: day))
        }
        cells += Array(repeating: nil, count: (7 - cells.count % 7) % 7)
        weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    /// I numeri dei giorni della settimana nell'ordine delle colonne (1 = domenica).
    public static func weekdayOrder(firstWeekday: Int) -> [Int] {
        (0..<7).map { (firstWeekday - 1 + $0) % 7 + 1 }
    }
}
