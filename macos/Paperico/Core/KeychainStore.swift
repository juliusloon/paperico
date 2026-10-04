import Foundation
import Security

/// 所有凭据保存在同一受保护的钥匙串记录；不在 UserDefaults 或磁盘缓存明文。
enum KeychainStore {
    private static let service = "com.paperico.native"
    static let unifiedAccount = "credentials.v1"

    enum Account: String, CaseIterable, Sendable {
        case llmApiKey = "llm.api-key"
        case mineruToken = "mineru.token"
        case mcpToken = "mcp.access-token"
    }

    struct ReadResult: Sendable {
        let value: String
        let status: OSStatus
        var needsAuthorization: Bool { status != errSecSuccess && status != errSecItemNotFound }
    }

    struct StoredItem: Sendable {
        let data: Data?
        let status: OSStatus
    }

    /// 注入底层访问，回归测试不会访问用户的真实钥匙串。
    struct Backend: Sendable {
        var read: @Sendable (String, Bool) -> StoredItem
        var write: @Sendable (String, Data, Bool) throws -> Void
        static let system = Backend(
            read: { KeychainStore.readItem($0, allowInteraction: $1) },
            write: { try KeychainStore.writeItem($0, data: $1, allowInteraction: $2) }
        )
    }

    private static func query(_ account: String, allowInteraction: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if !allowInteraction {
            // LAContext is for the data-protection keychain. Retain the noninteractive
            // option supported by our existing macOS file-based keychain records.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        return query
    }

    private static func readItem(_ account: String, allowInteraction: Bool) -> StoredItem {
        var query = query(account, allowInteraction: allowInteraction)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return StoredItem(data: item as? Data, status: status)
    }

    private static func writeItem(_ account: String, data: Data, allowInteraction: Bool) throws {
        let base = query(account, allowInteraction: allowInteraction)
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

/// 串行访问和进程内缓存：设置、解析与 MCP 共用一次读取的授权结果。
/// file-based keychain 的旧记录有各自的 ACL，迁移时不能绕过系统的逐项授权。
actor CredentialStore {
    static let shared = CredentialStore()
    typealias Account = KeychainStore.Account

    struct Envelope: Codable {
        var version = 1
        var values: [String: String]
    }

    struct Snapshot: Sendable {
        var results: [Account: KeychainStore.ReadResult]
        var error = ""
        subscript(_ account: Account) -> KeychainStore.ReadResult {
            results[account] ?? .init(value: "", status: errSecItemNotFound)
        }
        var needsAuthorization: Bool { results.values.contains { $0.needsAuthorization } }
    }

    private let backend: KeychainStore.Backend
    private var cached: Snapshot?
    private var unified = false

    init(backend: KeychainStore.Backend = .system) { self.backend = backend }

    func readAll(allowInteraction: Bool = false) -> Snapshot {
        if let cached, !cached.needsAuthorization || !allowInteraction { return cached }

        // Once the unified record exists, never fall back to possibly stale legacy values.
        if cached == nil || unified {
            let item = backend.read(KeychainStore.unifiedAccount, allowInteraction)
            if item.status == errSecSuccess {
                do {
                    guard let data = item.data else { throw PipelineError("钥匙串凭据记录缺少数据", .storageFailed) }
                    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                    guard envelope.version == 1 else { throw PipelineError("不支持此版本的钥匙串凭据记录", .storageFailed) }
                    unified = true
                    let snapshot = resolved(envelope.values)
                    cached = snapshot
                    return snapshot
                } catch {
                    // Do not overwrite a damaged or newer record with legacy credentials.
                    unified = true
                    let snapshot = blocked(errSecDecode, message: "无法读取已保存凭据：\(error.localizedDescription)")
                    cached = snapshot
                    return snapshot
                }
            }
            if item.status != errSecItemNotFound {
                unified = true
                let snapshot = blocked(item.status)
                cached = snapshot
                return snapshot
            }
            unified = false
        }

        var snapshot = cached ?? Snapshot(results: [:])
        for account in Account.allCases {
            if let result = snapshot.results[account], !result.needsAuthorization { continue }
            let item = backend.read(account.rawValue, allowInteraction)
            let value = item.data.flatMap { String(data: $0, encoding: .utf8) }
            let status = item.status == errSecSuccess && value == nil ? errSecDecode : item.status
            snapshot.results[account] = .init(value: value ?? "", status: status)
            if allowInteraction && status != errSecSuccess && status != errSecItemNotFound {
                // Cancellation ends this attempt; it must not trigger the next credential prompt.
                for remaining in Account.allCases where snapshot.results[remaining] == nil {
                    snapshot.results[remaining] = .init(value: "", status: errSecInteractionNotAllowed)
                }
                cached = snapshot
                return snapshot
            }
        }
        cached = snapshot
        if !snapshot.needsAuthorization && snapshot.results.values.contains(where: { !$0.value.isEmpty }) {
            // A silent migration may fail while the keychain is locked. Keep all readable legacy
            // values, leave old items intact, and retry migration on a later launch/save.
            do {
                try saveEnvelope(snapshot, allowInteraction: allowInteraction)
                unified = true
            } catch { /* The migration must not discard working credentials. */ }
        }
        return snapshot
    }

    func write(_ value: String, to account: Account) throws {
        var snapshot = readAll(allowInteraction: true)
        guard !snapshot.needsAuthorization else {
            throw PipelineError(snapshot.error.isEmpty ? "请先解锁已保存凭据，再保存新的密钥。" : snapshot.error, .storageFailed)
        }
        snapshot.results[account] = .init(value: value, status: value.isEmpty ? errSecItemNotFound : errSecSuccess)
        try saveEnvelope(snapshot, allowInteraction: true)
        unified = true
        cached = snapshot
    }

    private func saveEnvelope(_ snapshot: Snapshot, allowInteraction: Bool) throws {
        let values = Dictionary(uniqueKeysWithValues: snapshot.results.compactMap { account, result in
            result.value.isEmpty ? nil : (account.rawValue, result.value)
        })
        let data = try JSONEncoder().encode(Envelope(values: values))
        try backend.write(KeychainStore.unifiedAccount, data, allowInteraction)
    }

    private func resolved(_ values: [String: String]) -> Snapshot {
        Snapshot(results: Dictionary(uniqueKeysWithValues: Account.allCases.map { account in
            let value = values[account.rawValue] ?? ""
            return (account, .init(value: value, status: value.isEmpty ? errSecItemNotFound : errSecSuccess))
        }))
    }

    private func blocked(_ status: OSStatus, message: String = "") -> Snapshot {
        Snapshot(results: Dictionary(uniqueKeysWithValues: Account.allCases.map {
            ($0, .init(value: "", status: status))
        }), error: message)
    }
}
