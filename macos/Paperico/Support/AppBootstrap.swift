import Foundation

// MARK: - 进程级一次性初始化

enum AppBootstrap {
    /// `let` 静态常量的惰性求值由 runtime 保证线程安全且只跑一次,
    /// 不需要额外的锁或 @State 标记。
    private static let once: Void = {
        // 标准用户数据容器(Application Support/Paperico/{logs}),后续任何
        // 本地文件写入都走 AppPaths,不散落在容器根目录。
        AppPaths.install()
        // AsyncImage 走 `URLSession.shared`,而 macOS 的默认共享 URLCache 内存容量
        // 很小:阅读器一屏可达数十张图表,回滚/滚动时 AsyncImage 会反复回源。
        // 这里只放大内存容量(不动磁盘容量),让 /api/files 返回的 ETag 生效。
        URLCache.shared.memoryCapacity = 128 * 1024 * 1024
    }()

    static func install() { _ = once }
}
