import Foundation
import Security

/// 两个密钥(LLM API Key 与 MinerU Token)存 Keychain,其余配置存 UserDefaults。
enum KeychainStore {

    private static let service = "com.paperico.native"

    enum Account: String {
        case llmApiKey = "llm.api-key"
        case mineruToken = "mineru.token"
    }

    struct ReadResult: Sendable {
        let value: String
        let status: OSStatus
        var needsAuthorization: Bool { status != errSecSuccess && status != errSecItemNotFound }
    }

    /// 自动读取不唤起授权窗口;用户在设置页主动读取时才允许系统交互。
    static func read(_ account: Account, allowInteraction: Bool = false) -> ReadResult {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowInteraction {
            // 当前条目使用 macOS file-based keychain,保留其支持的非交互查询选项。
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let value = (item as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return ReadResult(value: value, status: status)
    }

    static func write(_ value: String, to account: Account) throws {
        let data = value.data(using: .utf8) ?? Data()
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        if data.isEmpty {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
            return
        }
        // Update in place: a failed save must not destroy an existing credential.
        let updated = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw failure(updated) }
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw failure(status) }
    }

    private static func failure(_ status: OSStatus) -> PipelineError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "状态码 \(status)"
        return PipelineError("无法保存钥匙串凭据：\(detail)", .storageFailed)
    }
}
