/// Dati iniziali al primo avvio (§ 6.2).
public enum DefaultData {
    public struct CategorySeed: Sendable {
        public let name: String
        public let kind: OperationKind
        public let symbol: String
        public let color: CategoryColor
    }

    public static let accountName = "Conto principale"

    public static let categories: [CategorySeed] = [
        CategorySeed(name: "Casa", kind: .expense, symbol: "house", color: .brown),
        CategorySeed(name: "Spesa", kind: .expense, symbol: "cart", color: .green),
        CategorySeed(name: "Trasporti", kind: .expense, symbol: "car", color: .blue),
        CategorySeed(name: "Ristoranti", kind: .expense, symbol: "fork.knife", color: .orange),
        CategorySeed(name: "Salute", kind: .expense, symbol: "cross.case", color: .red),
        CategorySeed(name: "Svago", kind: .expense, symbol: "gamecontroller", color: .purple),
        CategorySeed(name: "Abbonamenti", kind: .expense, symbol: "repeat", color: .indigo),
        CategorySeed(name: "Altro", kind: .expense, symbol: "ellipsis.circle", color: .gray),
        CategorySeed(name: "Stipendio", kind: .income, symbol: "banknote", color: .green),
        CategorySeed(name: "Rimborsi", kind: .income, symbol: "arrow.uturn.backward.circle", color: .teal),
        CategorySeed(name: "Regali", kind: .income, symbol: "gift", color: .pink),
        CategorySeed(name: "Altro", kind: .income, symbol: "ellipsis.circle", color: .gray),
    ]
}
