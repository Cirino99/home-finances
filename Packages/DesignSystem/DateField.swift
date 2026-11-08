import Core
import SwiftUI

/// Campo "Data" degli editor (§ 8.5, § 8.8).
///
/// Su iPhone e iPad è il `DatePicker` di sistema. Su Mac il calendario di sistema è il vecchio `NSDatePicker`,
/// piccolo e a dimensione fissa anche in stile `.graphical`: qui si apre invece `CalendarPicker` in un popover.
public struct DateField: View {
    private let title: LocalizedStringKey
    @Binding private var date: Date
    #if os(macOS)
    @State private var isPresented = false
    #endif

    public init(_ title: LocalizedStringKey, selection: Binding<Date>) {
        self.title = title
        _date = selection
    }

    public var body: some View {
        #if os(macOS)
        LabeledContent(title) {
            Button {
                isPresented.toggle()
            } label: {
                Label(DayFormat.long(day), systemImage: "calendar")
            }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                CalendarPicker(selection: dayBinding) { isPresented = false }
                    .padding(16)
            }
        }
        #else
        DatePicker(title, selection: $date, displayedComponents: .date)
        #endif
    }

    private var day: Day {
        Day(containing: date)
    }

    /// Gli editor salvano solo il giorno (§ 6.1): basta la mezzanotte del giorno scelto.
    private var dayBinding: Binding<Day> {
        Binding(
            get: { day },
            set: { newDay in date = newDay.date(in: .current) ?? date }
        )
    }
}

/// Calendario di un mese, nello stile dei calendari di sistema di iOS: giorni in cerchio, oggi evidenziato,
/// frecce per cambiare mese. Con la tastiera le frecce spostano il giorno e Invio conferma.
public struct CalendarPicker: View {
    @Binding private var selection: Day
    private let onPick: () -> Void
    private let today: Day
    private let calendar: Calendar
    @State private var month: YearMonth
    @State private var hovered: Day?
    @FocusState private var isFocused: Bool
    @ScaledMetric(relativeTo: .body) private var cellSize: CGFloat = 34

    /// `onPick` viene chiamato quando si sceglie un giorno con un clic o con Invio.
    public init(selection: Binding<Day>, today: Day = Day(containing: Date()), onPick: @escaping () -> Void = {}) {
        _selection = selection
        self.onPick = onPick
        self.today = today
        _month = State(initialValue: selection.wrappedValue.yearMonth)
        // Gregoriano come le date dell'app (§ 6.1), con lingua e primo giorno della settimana dell'utente.
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .current
        calendar.firstWeekday = Calendar.current.firstWeekday
        self.calendar = calendar
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    ForEach(MonthGrid.weekdayOrder(firstWeekday: calendar.firstWeekday), id: \.self) { weekday in
                        Text(calendar.shortStandaloneWeekdaySymbols[weekday - 1].uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: cellSize)
                            .accessibilityHidden(true)
                    }
                }
                let grid = MonthGrid(month: month, firstWeekday: calendar.firstWeekday)
                ForEach(grid.weeks.indices, id: \.self) { week in
                    GridRow {
                        ForEach(0..<7, id: \.self) { column in
                            cell(grid.weeks[week][column])
                        }
                    }
                }
            }
        }
        .fixedSize()
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(by: -1) }
        .onKeyPress(.rightArrow) { move(by: 1) }
        .onKeyPress(.upArrow) { move(by: -7) }
        .onKeyPress(.downArrow) { move(by: 7) }
        .onKeyPress(.return) {
            onPick()
            return .handled
        }
        .onAppear { isFocused = true }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(DayFormat.monthTitle(month))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 16)
            Button("Mese precedente", systemImage: "chevron.left") {
                if let previous = month.previous { month = previous }
            }
            .disabled(month.previous == nil)
            Button("Oggi") {
                selection = today
                month = today.yearMonth
            }
            Button("Mese successivo", systemImage: "chevron.right") {
                if let next = month.next { month = next }
            }
            .disabled(month.next == nil)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func cell(_ day: Day?) -> some View {
        if let day {
            let isSelected = day == selection
            let isToday = day == today
            Button {
                selection = day
                onPick()
            } label: {
                Text(verbatim: String(day.day))
                    .monospacedDigit()
                    .fontWeight(isToday || isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Color.white : isToday ? Color.accentColor : Color.primary)
                    .frame(width: cellSize, height: cellSize)
                    .background {
                        Circle().fill(
                            isSelected ? Color.accentColor : hovered == day ? Color.secondary.opacity(0.15) : Color.clear
                        )
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering in
                hovered = isHovering ? day : (hovered == day ? nil : hovered)
            }
            .accessibilityLabel(DayFormat.long(day))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint(isToday ? Text("Oggi") : Text(""))
        } else {
            Color.clear
                .frame(width: cellSize, height: cellSize)
                .accessibilityHidden(true)
        }
    }

    /// Frecce della tastiera: il giorno si sposta e, se cambia mese, il calendario lo segue.
    private func move(by days: Int) -> KeyPress.Result {
        selection = selection.adding(days: days)
        month = selection.yearMonth
        return .handled
    }
}
