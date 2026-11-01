import Core
import SwiftUI

public extension CategoryColor {
    var color: Color {
        switch self {
        case .gray: .gray
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        }
    }
}

public extension OperationKind {
    /// Colore degli importi. Mai da solo: il segno è sempre presente (§ 9).
    var color: Color {
        self == .income ? .income : .expense
    }
}

/// Icona di una categoria su sfondo del suo colore.
public struct CategoryIcon: View {
    private let symbol: String
    private let color: CategoryColor

    public init(symbol: String, color: CategoryColor) {
        self.symbol = symbol
        self.color = color
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.body)
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(color.color, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Riga di un'operazione negli elenchi (§ 8.2).
public struct OperationRow: View {
    private let item: OperationListItem
    private let today: Day

    /// `today` per la data relativa: "Oggi", "Ieri", "12 ott".
    public init(item: OperationListItem, today: Day) {
        self.item = item
        self.today = today
    }

    public var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(symbol: item.category.symbol, color: item.category.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.category.name)
                    .lineLimit(1)
                if let note = item.operation.note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(MoneyFormat.string(
                    amount: item.operation.amount,
                    kind: item.operation.kind,
                    currency: item.operation.currency
                ))
                .monospacedDigit()
                .foregroundStyle(item.operation.kind.color)
                Text(DayFormat.relative(item.operation.date, today: today))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
