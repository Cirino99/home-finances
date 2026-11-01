import Core
import Foundation
import GRDB

/// Conversione tra righe SQL e modelli di dominio: `Core` non conosce GRDB.
extension Row {
    func entityID<Entity>(_ column: String) throws -> EntityID<Entity> {
        let string: String = self[column]
        guard let uuid = UUID(uuidString: string) else {
            throw PersistenceError.corruptedValue(column: column)
        }
        return EntityID(rawValue: uuid)
    }

    func timestamp(_ column: String) throws -> Date {
        let string: String = self[column]
        return try Timestamp.date(string)
    }

    func kind(_ column: String) throws -> OperationKind {
        let string: String = self[column]
        guard let kind = OperationKind(rawValue: string) else {
            throw PersistenceError.corruptedValue(column: column)
        }
        return kind
    }

    func day(_ column: String) throws -> Day {
        let string: String = self[column]
        guard let day = Day(string: string) else {
            throw PersistenceError.corruptedValue(column: column)
        }
        return day
    }

    func periodTotals() -> PeriodTotals {
        PeriodTotals(income: self["income"], expense: self["expense"])
    }
}

extension Account {
    init(row: Row) throws {
        self.init(
            id: try row.entityID("id"),
            name: row["name"],
            currency: row["currency"],
            initialBalance: row["initial_balance"],
            isArchived: row["is_archived"],
            sortOrder: row["sort_order"],
            createdAt: try row.timestamp("created_at"),
            updatedAt: try row.timestamp("updated_at")
        )
    }
}

extension OperationCategory {
    /// `prefix` per le righe di una join, dove le colonne della categoria hanno un alias.
    init(row: Row, prefix: String = "") throws {
        let colorName: String = row[prefix + "color"]
        self.init(
            id: try row.entityID(prefix + "id"),
            name: row[prefix + "name"],
            kind: try row.kind(prefix + "kind"),
            symbol: row[prefix + "symbol"],
            color: CategoryColor(rawValue: colorName) ?? .gray,
            isArchived: row[prefix + "is_archived"],
            sortOrder: row[prefix + "sort_order"],
            createdAt: try row.timestamp(prefix + "created_at"),
            updatedAt: try row.timestamp(prefix + "updated_at")
        )
    }
}

extension FinanceOperation {
    init(row: Row) throws {
        self.init(
            id: try row.entityID("id"),
            kind: try row.kind("kind"),
            amount: row["amount"],
            currency: row["currency"],
            date: try row.day("date"),
            accountID: try row.entityID("account_id"),
            categoryID: try row.entityID("category_id"),
            note: row["note"],
            createdAt: try row.timestamp("created_at"),
            updatedAt: try row.timestamp("updated_at")
        )
    }
}

extension OperationListItem {
    init(row: Row) throws {
        self.init(
            operation: try FinanceOperation(row: row),
            category: try OperationCategory(row: row, prefix: "c_"),
            accountName: row["account_name"]
        )
    }
}

extension EntityID {
    /// Forma salvata nelle colonne `TEXT`.
    var databaseValue: String {
        rawValue.uuidString
    }
}
