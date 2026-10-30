import Foundation
import GRDB
import Testing
@testable import Persistence

struct AppDatabaseTests {
    @Test func opensInMemory() throws {
        let database = try AppDatabase.inMemory()
        #expect(try !database.sqliteVersion().isEmpty)
    }

    @Test func opensFileInWALMode() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try AppDatabase.open(at: directory.appending(path: AppDatabase.fileName))
        let journalMode = try database.writer.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        #expect(journalMode == "wal")
    }

    @Test func foreignKeysAreEnabled() throws {
        let database = try AppDatabase.inMemory()
        let enabled = try database.writer.read { db in
            try Bool.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        #expect(enabled == true)
    }

    @Test func defaultURLUsesBundleFolder() throws {
        let url = try AppDatabase.defaultURL(bundleIdentifier: "it.example.test")
        #expect(url.lastPathComponent == "homefinances.sqlite")
        #expect(url.deletingLastPathComponent().lastPathComponent == "it.example.test")
    }
}
