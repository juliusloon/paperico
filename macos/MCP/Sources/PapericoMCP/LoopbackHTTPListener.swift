import Foundation
@preconcurrency import Network
import MCP

/// A bounded HTTP/1.1 adapter for the SDK's stateless Streamable HTTP transport.
/// One exchange per connection; no arbitrary paths, CORS, uploads or file serving.
actor LoopbackHTTPListener {
    private let token: String
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private let queue = DispatchQueue(label: "com.paperico.mcp.loopback")
    private var listener: NWListener?
    private var starting: CheckedContinuation<UInt16, any Error>?
    private var stopping: [CheckedContinuation<Void, Never>] = []
    private var connections: [UUID: (NWConnection, Task<Void, Never>)] = [:]

    init(token: String, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.token = token
        self.handler = handler
    }

    func start(port: UInt16) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        let requestedPort = NWEndpoint.Port(rawValue: port)!
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: requestedPort)
        parameters.allowLocalEndpointReuse = false
        // requiredLocalEndpoint already specifies the address and port. Passing
        // the same nonzero port to NWListener(on:) is rejected by Network.framework.
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in Task { await self?.stateChanged(state) } }
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
        return try await withCheckedThrowingContinuation { continuation in
            starting = continuation
            listener.start(queue: queue)
        }
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port?.rawValue {
                starting?.resume(returning: port)
                starting = nil
            }
        case .failed(let error):
            starting?.resume(throwing: error)
            starting = nil
        case .cancelled:
            starting?.resume(throwing: CancellationError())
            starting = nil
            for continuation in stopping { continuation.resume() }
            stopping.removeAll()
        default: break
        }
    }

    func stop() async {
        let previous = listener
        listener = nil
        starting?.resume(throwing: CancellationError())
        starting = nil
        for (connection, task) in connections.values { task.cancel(); connection.cancel() }
        connections.removeAll()
        if let previous {
            await withCheckedContinuation { continuation in
                stopping.append(continuation)
                previous.cancel()
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard let port = listener?.port?.rawValue, connections.count < 16 else { connection.cancel(); return }
        let id = UUID(), token = token, handler = handler
        connection.start(queue: queue)
        let task = Task {
            await Self.serve(connection, port: port, token: token, handler: handler)
            self.finished(id)
        }
        connections[id] = (connection, task)
    }

    private func finished(_ id: UUID) { connections.removeValue(forKey: id) }

    private static func serve(_ connection: NWConnection, port: UInt16, token: String,
                              handler: @Sendable (HTTPRequest) async -> HTTPResponse) async {
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            connection.cancel()
        }
        defer { deadline.cancel(); connection.cancel() }
        await withTaskCancellationHandler {
            do {
                var parser = HTTPRequestParser(port: port, token: token)
                var request: HTTPRequest?
                while request == nil {
                    let bytes = try await receive(connection)
                    request = try parser.append(bytes)
                }
                try Task.checkCancellation()
                let response = await handler(request!)
                let body = response.bodyData ?? Data()
                guard body.count <= 12 * 1024 * 1024 else { throw HTTPRejection(code: 413, message: "Response too large; use paginated tools") }
                try await send(connection, code: response.statusCode, headers: response.headers, body: body)
            } catch let rejection as HTTPRejection {
                try? await send(connection, code: rejection.code, headers: [:], body: Data(rejection.message.utf8))
            } catch {
                // Never echo credentials, request bodies or local file paths in HTTP errors.
                try? await send(connection, code: 400, headers: [:], body: Data("Invalid or interrupted request".utf8))
            }
        } onCancel: { connection.cancel() }
    }

    private static func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: HTTPRejection(code: 400, message: complete ? "Incomplete request" : "Empty request")) }
            }
        }
    }

    private static func send(_ connection: NWConnection, code: Int, headers: [String: String], body: Data) async throws {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed", 413: "Content Too Large", 431: "Request Header Fields Too Large", 500: "Internal Server Error"][code] ?? "Error"
        var response = "HTTP/1.1 \(code) \(reason)\r\nConnection: close\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) where !["content-length", "connection", "cache-control"].contains(name.lowercased()) {
            guard !name.contains("\r"), !name.contains("\n"), !value.contains("\r"), !value.contains("\n") else { continue }
            response += "\(name): \(value)\r\n"
        }
        if !headers.keys.contains(where: { $0.lowercased() == "content-type" }) { response += "Content-Type: text/plain; charset=utf-8\r\n" }
        if code == 405 && !headers.keys.contains(where: { $0.lowercased() == "allow" }) { response += "Allow: POST\r\n" }
        if code == 401 { response += "WWW-Authenticate: Bearer realm=\"Paperico\"\r\n" }
        response += "\r\n"
        var bytes = Data(response.utf8)
        bytes.append(body)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: bytes, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

struct HTTPRejection: Error {
    let code: Int
    let message: String
}

struct HTTPRequestParser {
    let port: UInt16
    let token: String
    private var buffer = Data()
    private var head: (method: String, headers: [String: String], bodyStart: Int, length: Int)?

    init(port: UInt16, token: String) { self.port = port; self.token = token }

    mutating func append(_ bytes: Data) throws -> HTTPRequest? {
        buffer.append(bytes)
        if head == nil {
            guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                guard buffer.count <= 16 * 1024 else { throw HTTPRejection(code: 431, message: "Header too large") }
                return nil
            }
            guard separator.lowerBound <= 16 * 1024,
                  let text = String(data: buffer[..<separator.lowerBound], encoding: .utf8),
                  text.utf8.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }) else {
                throw HTTPRejection(code: 400, message: "Invalid header")
            }
            let lines = text.components(separatedBy: "\r\n")
            let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
            guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" else { throw HTTPRejection(code: 400, message: "HTTP/1.1 required") }
            guard requestLine[1] == "/mcp" else { throw HTTPRejection(code: 404, message: "Not found") }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw HTTPRejection(code: 400, message: "Invalid header") }
                let name = String(line[..<colon]).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                      headers[name] == nil, !value.contains("\r"), !value.contains("\n") else { throw HTTPRejection(code: 400, message: "Invalid or duplicate header") }
                headers[name] = value
            }
            // Validate Host as well as Origin: an arbitrary domain rebinding to
            // loopback cannot gain access, even if a browser can reach the port.
            let hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
            guard let host = headers["host"], hosts.contains(host.lowercased()) else { throw HTTPRejection(code: 403, message: "Invalid Host") }
            if let origin = headers["origin"], !hosts.map({ "http://\($0)" }).contains(origin.lowercased()) {
                throw HTTPRejection(code: 403, message: "Invalid Origin")
            }
            guard Self.equal(headers["authorization"] ?? "", "Bearer \(token)") else { throw HTTPRejection(code: 401, message: "Bearer token required") }
            guard headers["transfer-encoding"] == nil, headers["expect"] == nil else { throw HTTPRejection(code: 400, message: "Unsupported body framing") }
            let method = String(requestLine[0])
            guard method == "POST" else { throw HTTPRejection(code: 405, message: "Only POST is supported") }
            guard let lengthString = headers["content-length"], !lengthString.isEmpty,
                  lengthString.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(lengthString), length <= 1024 * 1024 else {
                throw HTTPRejection(code: 413, message: "Content-Length required, maximum 1 MiB")
            }
            head = (method, headers, separator.upperBound, length)
        }
        guard let head else { return nil }
        let expected = head.bodyStart + head.length
        guard buffer.count <= expected else { throw HTTPRejection(code: 400, message: "Pipelining is not supported") }
        guard buffer.count == expected else { return nil }
        return HTTPRequest(method: head.method, headers: head.headers, body: Data(buffer[head.bodyStart..<expected]), path: "/mcp")
    }

    private static func equal(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in a.indices { difference |= a[i] ^ b[i] }
        return difference == 0
    }
}
