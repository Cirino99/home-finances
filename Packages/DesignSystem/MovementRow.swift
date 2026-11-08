import Core
import SwiftUI

/// Riga di un trasferimento negli elenchi (§ 8.8).
public struct TransferRow: View {
    private let item: TransferListItem
    private let today: Day
    private let account: AccountID?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// `account` è il conto di riferimento, per esempio quello filtrato: l'importo prende il segno
    /// rispetto a quel conto. Senza, il trasferimento non ha segno (§ 8.3).
    public init(item: TransferListItem, today: Day, account: AccountID? = nil) {
        self.item = item
        self.today = today
        self.account = account
    }

    public var body: some View {
        // Con le dimensioni di accessibilità il testo non ci sta su una riga: si impila.
        let isLarge = dynamicTypeSize.isAccessibilitySize
        let layout = isLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            TransferIcon()
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title)
                    .lineLimit(isLarge ? nil : 1)
                if let note = item.transfer.note {
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
                Text(amountText)
                    .monospacedDigit()
                    .foregroundStyle(Color.transfer)
                Text(DayFormat.relative(item.transfer.date, today: today))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var amountText: String {
        let transfer = item.transfer
        if let signed = transfer.signedAmount(for: account) {
            return MoneyFormat.string(minorUnits: signed, currency: transfer.currency, signed: true)
        }
        return MoneyFormat.string(minorUnits: transfer.amount, currency: transfer.currency)
    }

    /// "Trasferimento, 200,00 €, da Conto principale a Risparmi, Oggi" (§ 8.8). Con un conto
    /// di riferimento l'importo ha il segno, come a schermo: dice se i soldi escono o entrano.
    private var accessibilityText: String {
        let transfer = item.transfer
        let parts: [String?] = [
            String(localized: "Trasferimento"),
            amountText,
            String(localized: "da \(item.fromAccountName) a \(item.toAccountName)"),
            DayFormat.relative(transfer.date, today: today),
            transfer.note,
        ]
        return parts.compactMap(\.self).joined(separator: ", ")
    }
}

/// Riga di un movimento: operazione o trasferimento.
public struct MovementRow: View {
    private let item: MovementListItem
    private let today: Day
    private let account: AccountID?

    /// `account`: conto di riferimento per il segno dei trasferimenti, vedi `TransferRow`.
    public init(item: MovementListItem, today: Day, account: AccountID? = nil) {
        self.item = item
        self.today = today
        self.account = account
    }

    public var body: some View {
        switch item {
        case .operation(let operation):
            OperationRow(item: operation, today: today)
        case .transfer(let transfer):
            TransferRow(item: transfer, today: today, account: account)
        }
    }
}
