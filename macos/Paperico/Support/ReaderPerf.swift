import Foundation
import OSLog

// MARK: - 阅读页性能追踪(默认关闭)
//
// 打开方式(二选一,无需重新编译):
//   defaults write com.paperico.Paperico "paperico:perf-trace" -bool true
//   或者 Xcode → Scheme → Run → Arguments → Environment: PAPERICO_PERF=1
// 关闭:把上面的值改回 false / 删掉。
//
// 用下面这条命令实时查看:
//   log stream --level default --predicate 'subsystem == "com.paperico.app"'

enum ReaderPerf {

    static var isEnabled: Bool {
        if let env = ProcessInfo.processInfo.environment["PAPERICO_PERF"], env == "1" { return true }
        return UserDefaults.standard.bool(forKey: "paperico:perf-trace")
    }

    private static let signposts = OSLog(subsystem: "com.paperico.app", category: "perf")

    // MARK: 计时

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func milliseconds(since start: UInt64) -> Double {
        Double(now() - start) / 1_000_000
    }

    /// 追踪未开启时几乎零成本:只有一个 bool 判断(返回 0 表示未开始计时)。
    static func start(_ label: String) -> UInt64 {
        guard isEnabled else { return 0 }
        os_signpost(.begin, log: signposts, name: "interval", "%{public}@", label)
        return now()
    }

    static func end(_ label: String, startedAt: UInt64) {
        guard startedAt > 0, isEnabled else { return }
        os_signpost(.end, log: signposts, name: "interval", "%{public}@", label)
        log("[%@] %.1f ms", label, milliseconds(since: startedAt))
    }

    static func log(_ format: String, _ args: CVarArg...) {
        guard isEnabled else { return }
        NSLog("[paperico.perf] " + format, args)
    }

    // MARK: 内存

    /// 当前进程常驻内存(MB)。用 `footprint` 而不是 `rss`,排除已丢弃的脏页,
    /// 与 Xcode Memory Report / Instruments All Heap 口径一致。
    static func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / (1024 * 1024)
    }

    // MARK: 计数器

    /// 一次 fetch + 首次渲染中,论文详情的请求解码与行数。
    static let storeFetch = PerfMeter()
    /// ReadingArea.documentBody 被求值的次数。
    static let documentBody = PerfCounter()
    /// ReadingArea.updateActiveBlock 被触发的次数(滚动时每帧都会)。
    static let activeBlockUpdates = PerfCounter()
    /// ReadingArea.updateTextProgress 被触发的次数。
    static let progressUpdates = PerfCounter()
    /// 真正写 UserDefaults 的次数(合并后应该远小于 progressUpdates)。
    static let progressPersisted = PerfCounter()
    /// 每帧间隔统计 → 滚动流畅度(FPS / p95 帧耗时)。
    static let frameIntervals = FrameStats()

    static func dumpSummary() {
        guard isEnabled else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var lines = ["---- Paperico 阅读页性能摘要 \(timestamp) ----"]
        lines.append(String(format: "  内存 footprint = %.1f MB", memoryFootprintMB()))
        lines.append(String(format: "  documentBody 求值次数 = %d", documentBody.current))
        lines.append(String(format: "  activeBlock 更新次数  = %d", activeBlockUpdates.current))
        lines.append(String(format: "  进度回调次数/持久化次数 = %d / %d", progressUpdates.current, progressPersisted.current))
        lines.append(String(
            format: "  Markdown 块缓存 命中/未命中 = %d / %d (未命中累计 %.1f ms)",
            PaperMarkdown.blockCacheHits.current,
            PaperMarkdown.blockCacheMisses.current,
            Double(PaperMarkdown.uncachedParseNanos.current) / 1_000_000))
        lines.append(String(
            format: "  AttributedString 缓存 命中/未命中 = %d / %d",
            PaperMarkdown.attributedCacheHits.current,
            PaperMarkdown.attributedCacheMisses.current))
        if let fps = frameIntervals.snapshot() {
            lines.append(String(
                format: "  帧间隔 平均=%.1f ms (%.0f FPS) p95=%.1f ms 最大=%.1f ms 样本=%d",
                fps.averageMs, fps.fps, fps.p95Ms, fps.maxMs, fps.samples))
        }
        lines.forEach { log("%@", $0) }
        persistSummary(lines.joined(separator: "\n") + "\n")
    }

    /// 摘要追加到 Application Support/Paperico/logs/perf-summary.log(超过 2MB 重开)。
    private static func persistSummary(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let url = AppPaths.logs.appendingPathComponent("perf-summary.log")
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64, size > 2_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - 计数器 / 计时器

/// 线程安全计数器(NSCache 与 SwiftUI 可能从不同线程读写数量统计)。
final class PerfCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func add(_ n: Int = 1) {
        lock.lock(); value += n; lock.unlock()
    }

    func reset() {
        lock.lock(); value = 0; lock.unlock()
    }

    var current: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// 累计耗时统计。
final class PerfMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var totalMs: Double = 0

    func record(_ ms: Double) {
        lock.lock()
        count += 1
        totalMs += ms
        lock.unlock()
    }

    var current: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    var total: Double {
        lock.lock(); defer { lock.unlock() }
        return totalMs
    }

    var average: Double {
        lock.lock(); defer { lock.unlock() }
        return count == 0 ? 0 : totalMs / Double(count)
    }
}

/// 环形缓冲的帧间隔统计:滚动时每一帧的间隔直接反映流畅度。
final class FrameStats: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double]
    private var capacity: Int
    private var lastTimestamp: UInt64?

    init(capacity: Int = 240) {
        self.capacity = capacity
        self.samples = []
        self.samples.reserveCapacity(capacity)
    }

    func recordFrame(at timestamp: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock()
        if let last = lastTimestamp {
            let deltaMs = Double(timestamp - last) / 1_000_000
            // 忽略超过 500 ms 的间隔(说明中间暂停/切后台,不是卡顿)。
            if deltaMs > 0, deltaMs < 500 {
                if samples.count == capacity { samples.removeFirst() }
                samples.append(deltaMs)
            }
        }
        lastTimestamp = timestamp
        lock.unlock()
    }

    func reset() {
        lock.lock(); samples.removeAll(keepingCapacity: true); lastTimestamp = nil; lock.unlock()
    }

    struct Snapshot {
        var averageMs: Double
        var p95Ms: Double
        var maxMs: Double
        var samples: Int
        var fps: Double { averageMs > 0 ? 1000 / averageMs : 0 }
    }

    func snapshot() -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let avg = sorted.reduce(0, +) / Double(sorted.count)
        let p95Index = min(sorted.count - 1, Int(Double(sorted.count) * 0.95))
        return Snapshot(averageMs: avg, p95Ms: sorted[p95Index], maxMs: sorted.last ?? 0, samples: sorted.count)
    }
}
