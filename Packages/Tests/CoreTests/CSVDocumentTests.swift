import Foundation
import Testing
@testable import Core

struct CSVDocumentTests {
    func makeItem(
        kind: OperationKind = .expense,
        amount: Int64 = 1250,
        note: String? = nil,
        category: String = "Spesa"
    ) throws -> OperationListItem {
        let date = Date(timeIntervalSince1970: 0)
        return OperationListItem(
            operation: FinanceOperation(
                id: OperationID(),
                kind: kind,
                amount: amount,
                currency: "EUR",
                date: try #require(Day(string: "2026-10-30")),
                accountID: AccountID(),
                categoryID: CategoryID(),
                note: note,
                createdAt: date,
                updatedAt: date
            ),
            category: OperationCategory(
                id: CategoryID(),
                name: category,
                kind: kind,
                symbol: "cart",
                color: .green,
                isArchived: false,
                sortOrder: 0,
                createdAt: date,
                updatedAt: date
            ),
            accountName: "Conto principale"
        )
    }

    func lines(_ data: Data) throws -> [String] {
        let text = try #require(String(data: data.dropFirst(3), encoding: .utf8))
        return text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
    }

    @Test func startsWithByteOrderMarkAndHeader() throws {
        let data = CSVDocument.data(for: [])
        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
        #expect(try lines(data) == ["data;tipo;importo;valuta;categoria;conto;nota"])
    }

    @Test func writesOperationFieldsWithDecimalComma() throws {
        let rows = try lines(CSVDocument.data(for: [
            makeItem(kind: .expense, amount: 123450, note: "caffè"),
            makeItem(kind: .income, amount: 5, category: "Stipendio"),
        ]))
        #expect(rows[1] == "2026-10-30;Uscita;1234,50;EUR;Spesa;Conto principale;caffè")
        #expect(rows[2] == "2026-10-30;Entrata;0,05;EUR;Stipendio;Conto principale;")
    }

    @Test func writesTransferAsSingleRow() throws {
        let date = Date(timeIntervalSince1970: 0)
        let transfer = AccountTransfer(
            id: TransferID(),
            amount: 20000,
            currency: "EUR",
            date: try #require(Day(string: "2026-11-07")),
            fromAccountID: AccountID(),
            toAccountID: AccountID(),
            note: "risparmi",
            createdAt: date,
            updatedAt: date
        )
        let rows = try lines(CSVDocument.data(forMovements: [
            .transfer(TransferListItem(transfer: transfer, fromAccountName: "Conto principale", toAccountName: "Risparmi")),
            .operation(makeItem(kind: .expense, amount: 500)),
        ]))
        #expect(rows.count == 3)
        #expect(rows[1] == "2026-11-07;Trasferimento;200,00;EUR;;Conto principale → Risparmi;risparmi")
        #expect(rows[2] == "2026-10-30;Uscita;5,00;EUR;Spesa;Conto principale;")
    }

    @Test func quotesFieldsWithSeparators() {
        #expect(CSVDocument.escaped("a;b") == "\"a;b\"")
        #expect(CSVDocument.escaped("dice \"ciao\"") == "\"dice \"\"ciao\"\"\"")
        #expect(CSVDocument.escaped("riga\nnuova") == "\"riga\nnuova\"")
        #expect(CSVDocument.escaped("normale") == "normale")
    }

    /// Una nota in un file importato non deve diventare una formula eseguita da Excel.
    @Test(arguments: ["=1+1", "+39 333", "-5", "@SOMMA(A1)", "=HYPERLINK(\"http://x\")"])
    func neutralizesFormulas(text: String) {
        let escaped = CSVDocument.escaped(text)
        let unquoted = escaped.hasPrefix("\"") ? String(escaped.dropFirst()) : escaped
        #expect(unquoted.hasPrefix("'"))
    }
}

struct ImportPreviewTests {
    func summary(id: String = "A", modified: TimeInterval?) -> DatabaseSummary {
        DatabaseSummary(
            databaseID: id,
            lastModifiedAt: modified.map { Date(timeIntervalSince1970: $0) },
            lastModifiedBy: nil,
            operationCount: 0,
            latestOperationDate: nil
        )
    }

    func preview(current: DatabaseSummary, incoming: DatabaseSummary) -> ImportPreview {
        ImportPreview(fileURL: URL(filePath: "/tmp/x"), current: current, incoming: incoming)
    }

    @Test func warnsWhenCurrentDataIsNewer() {
        #expect(preview(current: summary(modified: 200), incoming: summary(modified: 100)).currentIsNewer)
        #expect(!preview(current: summary(modified: 100), incoming: summary(modified: 200)).currentIsNewer)
        #expect(!preview(current: summary(modified: 100), incoming: summary(modified: 100)).currentIsNewer)
        #expect(preview(current: summary(modified: 100), incoming: summary(modified: nil)).currentIsNewer)
        #expect(!preview(current: summary(modified: nil), incoming: summary(modified: 100)).currentIsNewer)
    }

    @Test func detectsDifferentDatabase() {
        #expect(preview(current: summary(id: "A", modified: nil), incoming: summary(id: "B", modified: nil)).isDifferentDatabase)
        #expect(!preview(current: summary(id: "A", modified: nil), incoming: summary(id: "A", modified: nil)).isDifferentDatabase)
    }
}
