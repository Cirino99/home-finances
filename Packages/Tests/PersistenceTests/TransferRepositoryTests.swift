import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

struct TransferRepositoryTests {
    @Test func createsAndReadsTransfer() async throws {
        let fixture = try await Fixture()
        let savings = try await fixture.addAccount("Risparmi")
        let created = try await fixture.addTransfer(
            amount: 20000, on: "2026-11-07", from: fixture.account, to: savings, note: "  fondo  "
        )

        #expect(created.currency == "EUR")
        #expect(created.note == "fondo", "Nota normalizzata")
        #expect(created.createdAt == fixture.clock.now)
        #expect(try await fixture.database.transfers.transfer(created.id) == created)

        let item = try #require(try await fixture.database.transfers.observeItem(created.id).firstValue() ?? nil)
        #expect(item.transfer == created)
        #expect(item.fromAccountName == fixture.account.name)
        #expect(item.toAccountName == "Risparmi")
    }

    @Test func rejectsInvalidDrafts() async throws {
        let fixture = try await Fixture()
        let savings = try await fixture.addAccount()

        await #expect(throws: TransferDraftError.sameAccount) {
            try await fixture.addTransfer(amount: 100, on: "2026-11-07", from: savings, to: savings)
        }
        await #expect(throws: TransferDraftError.amountNotPositive) {
            try await fixture.addTransfer(amount: 0, on: "2026-11-07", from: fixture.account, to: savings)
        }
        #expect(try await fixture.movements().isEmpty)
    }

    @Test func rejectsUnknownAccount() async throws {
        let fixture = try await Fixture()
        await #expect(throws: RepositoryError.notFound) {
            try await fixture.database.transfers.create(TransferDraft(
                amount: 100,
                date: try #require(Day(string: "2026-11-07")),
                fromAccountID: fixture.account.id,
                toAccountID: AccountID()
            ))
        }
    }

    @Test func rejectsDifferentCurrencies() async throws {
        let fixture = try await Fixture()
        let dollars = try await fixture.addAccount("Dollari", currency: "USD")
        await #expect(throws: RepositoryError.currencyMismatch) {
            try await fixture.addTransfer(amount: 100, on: "2026-11-07", from: fixture.account, to: dollars)
        }
    }

    @Test func updatesTransferKeepingCreationDate() async throws {
        let fixture = try await Fixture()
        let savings = try await fixture.addAccount()
        let created = try await fixture.addTransfer(amount: 100, on: "2026-11-07", from: fixture.account, to: savings)

        fixture.clock.advance(by: 60)
        let updated = try await fixture.database.transfers.update(created.id, with: TransferDraft(
            amount: 250,
            date: try #require(Day(string: "2026-11-08")),
            fromAccountID: savings.id,
            toAccountID: fixture.account.id,
            note: "rientro"
        ))

        #expect(updated.amount == 250)
        #expect(updated.fromAccountID == savings.id)
        #expect(updated.toAccountID == fixture.account.id)
        #expect(updated.createdAt == created.createdAt)
        #expect(updated.updatedAt == fixture.clock.now)
        #expect(try await fixture.database.transfers.transfer(created.id) == updated)
    }

    @Test func deletesTransfer() async throws {
        let fixture = try await Fixture()
        let savings = try await fixture.addAccount()
        let created = try await fixture.addTransfer(amount: 100, on: "2026-11-07", from: fixture.account, to: savings)

        try await fixture.database.transfers.delete(created.id)
        #expect(try await fixture.database.transfers.transfer(created.id) == nil)
        #expect(try await fixture.database.transfers.observeItem(created.id).firstValue() == .some(nil))
    }

    @Test func missingTransferIsNotFound() async throws {
        let fixture = try await Fixture()
        let savings = try await fixture.addAccount()
        await #expect(throws: RepositoryError.notFound) {
            try await fixture.database.transfers.delete(TransferID())
        }
        await #expect(throws: RepositoryError.notFound) {
            try await fixture.database.transfers.update(TransferID(), with: TransferDraft(
                amount: 100,
                date: try #require(Day(string: "2026-11-07")),
                fromAccountID: fixture.account.id,
                toAccountID: savings.id
            ))
        }
    }

    @Test func writesUpdateMetadata() async throws {
        let fixture = try await Fixture()
        let savings = try await fixture.addAccount()
        fixture.clock.advance(by: 3600)
        try await fixture.addTransfer(amount: 100, on: "2026-11-07", from: fixture.account, to: savings)

        let metadata = try fixture.database.metadata()
        #expect(metadata.lastModifiedAt == fixture.clock.now)
        #expect(metadata.lastModifiedBy == "Test")
    }

    // MARK: Conti

    @Test func accountUsedOnlyByTransfersIsArchived() async throws {
        let fixture = try await Fixture()
        let savings = try await fixture.addAccount()
        let spare = try await fixture.addAccount("Contanti")
        try await fixture.addTransfer(amount: 100, on: "2026-11-07", from: savings, to: spare)

        #expect(try await fixture.database.accounts.remove(savings.id) == .archived)
        #expect(try await fixture.database.accounts.remove(spare.id) == .archived)
    }

    @Test func unusedAccountIsDeleted() async throws {
        let fixture = try await Fixture()
        let savings = try await fixture.addAccount()
        #expect(try await fixture.database.accounts.remove(savings.id) == .deleted)
    }
}
