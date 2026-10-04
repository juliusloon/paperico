import Foundation
import Observation
import Security
import PapericoMCP

/// App-owned lifecycle and credentials; the protocol package never opens a library.
@MainActor
@Observable
final class MCPStore {
    private(set) var enabled = UserDefaults.standard.bool(forKey: "paperico:mcp-enabled")
    private(set) var busy = false
    private(set) var endpoint = ""
    private(set) var token = ""
    private(set) var error = ""
    var running: Bool { !endpoint.isEmpty }

    private let server: PapericoMCPServer

    init(library: PaperLibrary) {
        server = PapericoMCPServer { name, arguments in
            let result = try await library.automationQuery(name, arguments: arguments)
            return PapericoMCPPayload(json: result.json, image: result.image, mimeType: result.mimeType)
        }
    }

    func restore() async {
        guard enabled else { return }
        await start(allowInteraction: false)
    }

    func setEnabled(_ value: Bool) {
        guard !busy else { return }
        enabled = value
        UserDefaults.standard.set(value, forKey: "paperico:mcp-enabled")
        busy = true
        Task {
            if value { busy = false; await start(allowInteraction: true) }
            else {
                busy = true
                endpoint = ""
                token = ""
                error = ""
                await server.stop()
                busy = false
            }
        }
    }

    func retry() { Task { await start(allowInteraction: true) } }

    func rotateToken() {
        guard enabled, !busy else { return }
        busy = true
        Task {
            do {
                let value = try Self.newToken()
                try KeychainStore.write(value, to: .mcpToken)
                endpoint = ""
                token = ""
                await server.stop()
                busy = false
                await start(allowInteraction: true)
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }

    private func start(allowInteraction: Bool) async {
        guard enabled, !busy, !running else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            let saved = KeychainStore.read(.mcpToken, allowInteraction: allowInteraction)
            guard !saved.needsAuthorization else { throw AutomationError("MCP 凭据需要钥匙串授权，请点击重试。") }
            var value = saved.value
            if value.isEmpty {
                // Automatic startup must not create an interactive keychain item.
                guard allowInteraction else { throw AutomationError("MCP 凭据缺失，请点击重试以创建。") }
                value = try Self.newToken()
                try KeychainStore.write(value, to: .mcpToken)
            }
            let preferred = UInt16(exactly: UserDefaults.standard.integer(forKey: "paperico:mcp-port")) ?? 0
            let url: URL
            do { url = try await server.start(token: value, port: preferred) }
            catch {
                guard preferred != 0 else { throw error }
                // If another process owns the remembered port, choose a fresh one.
                url = try await server.start(token: value)
            }
            UserDefaults.standard.set(url.port ?? 0, forKey: "paperico:mcp-port")
            token = value
            endpoint = url.absoluteString
        } catch { self.error = error.localizedDescription }
    }

    var clientConfiguration: String {
        guard running else { return "" }
        let value: [String: Any] = ["mcpServers": ["paperico": ["url": endpoint, "headers": ["Authorization": "Bearer \(token)"]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    var vscodeConfiguration: String {
        guard running else { return "" }
        let value: [String: Any] = ["servers": ["paperico": ["type": "http", "url": endpoint, "headers": ["Authorization": "Bearer \(token)"]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    var claudeCommand: String {
        // Endpoint is generated locally; token is hex, so neither needs shell quoting beyond these literals.
        "claude mcp add --transport http paperico '\(endpoint)' --header 'Authorization: Bearer \(token)'"
    }

    private static func newToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AutomationError("无法生成 MCP 访问凭据。")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
