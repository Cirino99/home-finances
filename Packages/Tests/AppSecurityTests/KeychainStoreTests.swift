import Foundation
import Security
import Testing
@testable import AppSecurity

/// Il Keychain vero. Richiede un processo firmato con un Team: `swift test` e alcuni runner
/// non lo sono, e il sistema risponde -34018. In quel caso il test non verifica nulla, e lo dichiara.
struct KeychainStoreTests {
    let store = KeychainStore(service: "it.simonecirino.homefinances.tests.\(UUID().uuidString)")
    let key = SecureStoreKey(rawValue: "test")

    /// Esegue `body`, salvo che il Keychain non sia disponibile in questo processo.
    private func ifKeychainAvailable(_ body: () throws -> Void) throws {
        defer { try? store.set(nil, for: key) }
        do {
            try body()
        } catch let error as KeychainError where error.status == errSecMissingEntitlement {
            print("Keychain non disponibile in questo processo: test non eseguito.")
        }
    }

    @Test func readsWhatItSaved() throws {
        try ifKeychainAvailable {
            #expect(try store.data(for: key) == nil)
            try store.set(Data([1, 2, 3]), for: key)
            #expect(try store.data(for: key) == Data([1, 2, 3]))
        }
    }

    @Test func overwritesExistingValue() throws {
        try ifKeychainAvailable {
            try store.set(Data([1]), for: key)
            try store.set(Data([2]), for: key)
            #expect(try store.data(for: key) == Data([2]))
        }
    }

    @Test func nilRemovesTheValue() throws {
        try ifKeychainAvailable {
            try store.set(Data([1]), for: key)
            try store.set(nil, for: key)
            #expect(try store.data(for: key) == nil)
            // Rimuovere ciò che non c'è non è un errore.
            try store.set(nil, for: key)
        }
    }
}
