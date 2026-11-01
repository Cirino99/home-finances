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

/// Riga di un'operazione negli elenchi (§ 8.2). Il segno è sempre presente: il colore non è mai l'unico indicatore.
public struct OperationRow: View {
    private let item: OperationListItem

    public init(item: OperationListItem) {
        self.item = item
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
                Text(amountText)
                    .monospacedDigit()
                    .foregroundStyle(item.operation.kind == .income ? Color.income : Color.expense)
                if let date = item.operation.date.date() {
                    Text(date, format: .dateTime.day().month())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var amountText: String {
        MoneyFormat.string(
            amount: item.operation.amount,
            kind: item.operation.kind,
            currency: item.operation.currency
        )
    }
}
