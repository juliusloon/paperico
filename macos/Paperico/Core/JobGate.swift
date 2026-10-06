import Foundation

/// 管线并发额度:写在闸门旁边而不是调用点,便于测试与文档引用同一组数字。
///
/// 本地 MinerU 与云端 MinerU 是**不同的供给**:本地是这台机器上的同一个服务实例,
/// 同时提交多份只会互相抢占 CPU/GPU,因此串行化;云端与 LLM 是远端服务,并发安全。
enum JobGateLimit {
    /// 本地 MinerU 解析:同一台机器上的同一个服务,一次只跑一篇。
    static let localParse = 1
    /// 云端 MinerU 上传/解析:远端服务,允许 2 并发。
    static let cloudParse = 2
    /// 模型调用:远端服务,允许 2 并发。
    static let llm = 2
}

/// FIFO concurrency gate. Cancellation removes queued work without leaking a permit.
actor JobGate {
    private let limit: Int
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(limit: Int) { self.limit = max(1, limit) }

    /// 公开只读容量,便于测试断言额度而不必靠并发时序推断。
    var capacity: Int { limit }

    func acquire() async throws {
        try Task.checkCancellation()
        if running < limit {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let position = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: position).continuation.resume(throwing: CancellationError())
    }

    func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume()
        } else {
            running = max(0, running - 1)
        }
    }

    func withPermit<T>(_ operation: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
}
