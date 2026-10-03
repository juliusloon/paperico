import Foundation

// MARK: - 标准用户数据目录
//
// 沙盒开启时,这些目录自动落在 app 容器内:
//   ~/Library/Containers/com.paperico.native/Data/Library/Application Support/Paperico/
// 偏好与阅读进度在 UserDefaults(容器 Preferences/com.paperico.native.plist);
// 导出笔记由用户通过原生保存面板自选位置;这里存放 app 自己管理的文件
// (诊断/性能日志等),遵循 macOS 标准目录规范。

enum AppPaths {

    /// Application Support/Paperico — app 自己的数据根目录。
    static let appSupport: URL = makeDir(.applicationSupportDirectory)
        .appendingPathComponent("Paperico", isDirectory: true)

    /// 诊断与性能日志(logs/perf-summary.log)。
    static let logs: URL = appSupport.appendingPathComponent("logs", isDirectory: true)

    private static let installed: Void = {
        for directory in [appSupport, logs] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }()

    /// 幂等创建目录结构;在 AppBootstrap 里随进程初始化调用一次。
    static func install() { _ = installed }

    private static func makeDir(_ search: FileManager.SearchPathDirectory) -> URL {
        FileManager.default.urls(for: search, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }
}
