import Foundation
import Security

public enum KeychainHelper {
    private static let service = "com.jiaqianjing.XiaoPen"

    public struct StorageError: LocalizedError {
        public let status: OSStatus
        public var errorDescription: String? {
            if status == errSecInteractionNotAllowed {
                return "已有密钥需要钥匙串授权，请点击“读取已有密钥”。"
            }
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "状态码 \(status)"
            return "钥匙串操作失败：\(detail)"
        }
    }

    public enum ReadError: LocalizedError, Equatable, Sendable {
        case timedOut
        case invalidTimeout

        public var errorDescription: String? {
            switch self {
            case .timedOut: return "读取钥匙串超时，请在设置中点击“读取已有密钥”后重试。"
            case .invalidTimeout: return "钥匙串读取等待时间必须是大于零的有限秒数。"
            }
        }
    }

    private static func query(key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    public static func save(key: String, data: String) throws {
        let identity = query(key: key)
        let value = [kSecValueData as String: Data(data.utf8)]
        var status = SecItemUpdate(identity as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(identity.merging(value, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StorageError(status: status) }
        // Remove only our legacy unscoped item after the new value has safely persisted.
        if isLegacyAccount(key) { _ = SecItemDelete(legacyQuery(key: key) as CFDictionary) }
    }

    public static func load(key: String) -> String? {
        try? readKey(key: key)
    }

    public static func readKey(key: String, allowUserInteraction: Bool = false) throws -> String? {
        try readKey(key: key, allowUserInteraction: allowUserInteraction, readOperation: copyMatching)
    }

    /// The system query runs in the background. Cancellation and the deadline end the
    /// caller's wait even if the synchronous Keychain API has not returned yet.
    public static func readKeyAsync(key: String, allowUserInteraction: Bool = false,
                                    timeout: TimeInterval = 8) async throws -> String? {
        try await readKeyAsync(timeout: timeout) {
            try readKey(key: key, allowUserInteraction: allowUserInteraction)
        }
    }

    static func readKeyAsync(timeout: TimeInterval,
                             readOperation: @escaping @Sendable () throws -> String?) async throws -> String? {
        try await AsyncKeychainRead.perform(timeout: timeout, operation: readOperation)
    }

    // The injectable operation lets tests verify status handling without accessing a real keychain.
    static func readKey(key: String, allowUserInteraction: Bool = false,
                        readOperation: ([String: Any]) -> (status: OSStatus, data: Data?)) throws -> String? {
        func read(_ identity: [String: Any]) throws -> String? {
            var query = identity
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecUseAuthenticationUI as String] = allowUserInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
            let (status, data) = readOperation(query)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw StorageError(status: status) }
            guard let data, let value = String(data: data, encoding: .utf8) else {
                throw StorageError(status: errSecDecode)
            }
            return value
        }

        if let value = try read(query(key: key)) { return value }
        // Passive reads preserve the legacy item. Only an explicit save performs migration.
        guard isLegacyAccount(key) else { return nil }
        return try read(legacyQuery(key: key))
    }

    private static func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    private static func legacyQuery(key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "",
         kSecAttrAccount as String: key]
    }

    private static func isLegacyAccount(_ key: String) -> Bool {
        ["anthropic_api_key", "openai_api_key"].contains(key)
    }

    public static func delete(key: String) throws {
        let identities = isLegacyAccount(key) ? [query(key: key), legacyQuery(key: key)] : [query(key: key)]
        for identity in identities {
            let status = SecItemDelete(identity as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError(status: status) }
        }
    }
}
