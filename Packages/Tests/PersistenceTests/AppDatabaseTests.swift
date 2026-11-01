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

    @Test func readsDoNotBlockDuringWritesOnFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try AppDatabase.open(at: directory.appending(path: AppDatabase.fileName))
        try await database.seedIfNeeded(currency: "EUR")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await database.writer.write { db in
                    for index in 0..<2000 {
                        try db.execute(
                            sql: "INSERT INTO app_metadata (key, value) VALUES (?, 'x')",
                            arguments: ["test-\(index)"]
                        )
                    }
                }
            }
            for _ in 0..<20 {
                group.addTask {
                    // Lettura asincrona: più lettori del pool attendono senza bloccare un thread.
                    let isSeeded = try await database.writer.read { db in
                        try Row.fetchOne(db, sql: "SELECT 1 FROM account LIMIT 1") != nil
                    }
                    #expect(isSeeded)
                }
            }
            try await group.waitForAll()
        }
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
