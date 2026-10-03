import Foundation

// MARK: - 进程级一次性初始化

enum AppBootstrap {
    /// `let` 静态常量的惰性求值由 runtime 保证线程安全且只跑一次,
    /// 不需要额外的锁或 @State 标记。
    private static let once: Void = {
        // 标准用户数据容器(Application Support/Paperico/{logs}),后续任何
        // 本地文件写入都走 AppPaths,不散落在容器根目录。
        AppPaths.install()

    }()

    static func install() { _ = once }
}
