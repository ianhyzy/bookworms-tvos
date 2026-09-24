import Foundation
import Security

enum CredentialStore {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "gay.ian.Bookworms",
            kSecAttrAccount as String: "hardcover-token",
        ]
    }

    static func read(account: String = "hardcover-token") -> String? {
        if OfflineTestPolicy.isEnabled { return nil }
        let measurement = PerformanceDiagnostics.begin("KeychainRead")
        defer { measurement.end() }
        var request = query
        request[kSecAttrAccount as String] = account
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, account: String = "hardcover-token") throws {
        if OfflineTestPolicy.isEnabled { throw CredentialError.saveFailed }
        var query = query
        query[kSecAttrAccount as String] = account
        let data = Data(token.utf8)
        let status = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw CredentialError.saveFailed
            }
        } else if status != errSecSuccess {
            throw CredentialError.saveFailed
        }
    }

    static func remove(account: String = "hardcover-token") {
        if OfflineTestPolicy.isEnabled { return }
        var query = query
        query[kSecAttrAccount as String] = account
        SecItemDelete(query as CFDictionary)
    }

    enum CredentialError: LocalizedError {
        case saveFailed
        var errorDescription: String? {
            "The credential could not be saved securely. Try saving it again."
        }
    }
}
