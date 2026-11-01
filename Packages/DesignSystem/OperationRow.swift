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
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 34

    public init(symbol: String, color: CategoryColor) {
        self.symbol = symbol
        self.color = color
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.body)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.color, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Riga di un'operazione negli elenchi (§ 8.2).
public struct OperationRow: View {
    private let item: OperationListItem
    private let today: Day
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// `today` per la data relativa: "Oggi", "Ieri", "12 ott".
    public init(item: OperationListItem, today: Day) {
        self.item = item
        self.today = today
    }

    public var body: some View {
        // Con le dimensioni di accessibilità il testo non ci sta su una riga: si impila.
        let isLarge = dynamicTypeSize.isAccessibilitySize
        let layout = isLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            CategoryIcon(symbol: item.category.symbol, color: item.category.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.category.name)
                    .lineLimit(isLarge ? nil : 1)
                if let note = item.operation.note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(isLarge ? 3 : 1)
                }
            }
            if !isLarge {
                Spacer()
            }
            VStack(alignment: isLarge ? .leading : .trailing, spacing: 2) {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// "Uscita, 45,20 €, Spesa, Oggi" (§ 9). L'importo senza segno: il tipo lo dice già a parole.
    private var accessibilityText: String {
        let operation = item.operation
        let parts: [String?] = [
            operation.kind == .income ? String(localized: "Entrata") : String(localized: "Uscita"),
            MoneyFormat.string(minorUnits: operation.amount, currency: operation.currency),
            item.category.name,
            DayFormat.relative(operation.date, today: today),
            operation.note,
        ]
        return parts.compactMap(\.self).joined(separator: ", ")
    }
}
