# Paperico 原生 App

v0.3.0 是独立 SwiftUI 应用。PDF、解析结构、对话和笔记由原生代码持久化；解析与模型请求
直连用户配置的服务。运行 App 不需要 Python。当前 target 为 macOS 26+，构建需要 Xcode 26+。

## 构建、运行和验证

在仓库根目录运行：

```bash
./script/build_and_run.sh             # 构建、启动
./script/build_and_run.sh --verify    # 确认新进程已运行
./script/build_and_run.sh --build-only
./script/build_and_run.sh --debug
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/check.sh                     # 核心回归 + App 构建
./script/check.sh --with-backend      # 额外检查旧 API 组件
```

脚本为本次运行选择标准路径的 Xcode，不修改系统的 xcode-select 设置。
需要验证 Release 时可设置 `PAPERICO_CONFIGURATION=Release`；`PAPERICO_DERIVED_DATA` 可指定已有构建目录。

构建日志位于 `macos/build/build-local.log`；Debug bundle 位于
`macos/build/DerivedData-Local/Build/Products/Debug/Paperico.app`。
也可打开 `Paperico.xcodeproj`，选择 Paperico / My Mac 后运行。

App 保持单一工作台。⌘1–⌘3 页面导航，⌘, 直接跳转到工作台内的设置页；重复按键复用当前窗口。
Swift 文件由工程的文件系统同步组自动发现，增删源码不需要重新生成 pbxproj。

SwiftPM 包仅服务于核心测试：

```bash
# Xcode 已选中时，可独立运行：
swift test --package-path macos
./script/check_markdown_rendering.sh
```

它不替代 App 的 Xcode target。原生回归使用临时目录和合成数据，不读取真实论文库，
也不调用模型或 MinerU。
Markdown 渲染回归在隐藏的 SwiftUI 容器中重放流式表格，覆盖不完整行、列数变化与窄面板，验证实际视图不会越界。

## 代码边界

- `App/PapericoApp.swift`：场景与命令；`AppModel.swift`：依赖装配与启动；
  `AppEnvironment.swift`：工作台和设置场景共用的依赖注入。
- `Stores/`：按 Settings、Projects、Papers、Reader、Chat 分文件组织。
- `Core/PaperLibrary.swift`：串行本地业务事务；LibraryIndex / LibraryFiles：格式与 IO。
- `Core/PaperPipeline.swift`、`JobGate.swift`：分阶段处理、取消、重试与并发许可。
- `Core/ChatService.swift`、`AnalysisEngine.swift`：证据上下文与分析请求。
- `Pages/Reader/PaperDocumentView.swift`：离线正文与原生交互桥；`ReaderDivider.swift`：屏幕坐标分隔柄输入。
- `reader-renderer/`：Markdown / KaTeX 源码、固定依赖与生成脚本；`Resources/Reader/`：已打包的离线资源。
- `Pages/LibraryManagementSheet.swift`：主工作台内的处理任务与回收站浮层；`Pages/Reader/`：阅读器。
- `Components/LocalPaperImage.swift`：后台下采样与有上限的本地图像缓存。

详细的数据、状态和已知限制见 [架构分析](../docs/architecture.md)。

## 数据与凭据

数据根目录位于 App 沙盒的 `Application Support/Paperico/`，包含 library.json、pdfs、
papers、mineru_output、analyses 与 logs。普通服务设置和阅读偏好用 UserDefaults；两个
凭据用 Keychain。App Sandbox 授权网络客户端和用户选定文件读写。

阅读外观中的背景透明度与玻璃透明度分别保存，拖动即时生效；玻璃控件供 build
确认组件材质，文字与图标不随之变淡。PDF 阅读进度包含页内位置，逻辑链与目录共用章节层级。

删除先移入回收站，数据持续保留；回收站支持逐篇确认永久删除全部关联文件，没有自动清空。
云端解析任务保存 ID；“继续处理”复用已有任务或解析结果，“重新解析 PDF”提交新任务。
处理任务浮层显示上传、排队、页数与下载进度。MinerU 返回 `pending` 时继续等待同一任务，
不因本地观察窗口结束而报解析失败，也不占用上传许可。实际开始解析后单独计算处理超时。
`mineru_output/<id>/cloud-status.json` 保存最后状态、错误与请求 trace ID，不保存凭据或签名结果链接。
旧后端 SQLite / Fernet 与新版数据
独立，目前没有自动导入迁移。请保留旧目录和数据库。

## DMG

```bash
./macos/scripts/make_dmg.sh CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

Release bundle 位于 `macos/build/DerivedData-Release/Build/Products/Release/`，DMG 位于
`macos/build/Paperico-0.3.0.dmg`。本地临时签名不等同于 Developer ID 签名和公证。
正式分发可设置 `PAPERICO_SIGN_IDENTITY`，并自行完成所需的公证流程。

## MCP 连接

在「设置 → MCP 连接」启用只读服务，复制 Claude Code、Cursor 或 VS Code 配置。
提供 10 个工具及论文资源；默认关闭，要求 App 保持运行。
使用方式、调研修正与后续路线见 [MCP 文档](../docs/mcp.md)。

## 旧 API 契约

`Models/Models.swift` 保留与后端相兼容的 DTO 结构。`scripts/check_api_contract.py` 校验
这份字段契约，用于兼容维护；当前 App 不从该 API 读取数据。

```bash
backend/.venv/bin/python macos/scripts/check_api_contract.py --file backend/tests/openapi_snapshot.json
```
