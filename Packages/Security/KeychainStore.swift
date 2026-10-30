import Foundation
import Security

/// Voci "generic password" del Keychain, accessibili solo a dispositivo sbloccato
/// e mai migrate su altri dispositivi (`WhenUnlockedThisDeviceOnly`, § 5.2).
public struct KeychainStore: SecureStore {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func data(for key: SecureStoreKey) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func set(_ data: Data?, for key: SecureStoreKey) throws {
        let query = baseQuery(for: key)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(for key: SecureStoreKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            // Su macOS usa lo stesso Keychain di iOS, l'unico che rispetta le classi di accessibilità.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "errore sconosciuto"
        return "Keychain \(status): \(message)"
    }
}
