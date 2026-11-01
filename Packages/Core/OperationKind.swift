/// Tipo di operazione. Determina il segno dell'importo, che su disco è sempre positivo (§ 6.1).
public enum OperationKind: String, Sendable, Codable, CaseIterable {
    case income
    case expense
}
