import Foundation
import Security

/// Generic-password Keychain items under one service, accessible after first unlock.
/// Accounts are stable UUID strings by convention. Errors carry only the OSStatus.
public struct KeychainStore: SecretStoring {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        // Fail closed on undecodable data: reporting "missing" could let a caller overwrite it.
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedStatus(errSecDecode)
        }
        return value
    }

    public func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        var add = baseQuery(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let attrs: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let status = SecItemUpdate(baseQuery(account: account) as CFDictionary, attrs as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        } else if addStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
