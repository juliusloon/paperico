# Paperico macOS 架构

> 适用版本：0.2.5（build 7），`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 见 `Paperico.xcodeproj/project.pbxproj`。
> v0.3.0（build 8）的 MCP 与发布扩展见第 19 节；此前逐文件解读以 v0.2.5 为基线。
> 本文是 `macos/` 目录的**逐文件解读**：每个文件负责什么、实现什么功能、出现在哪个页面/哪条链路。
> 仓库级的重构脉络与决策记录见 [`../docs/architecture.md`](../docs/architecture.md)；构建与验证的操作说明见 [`README.md`](README.md)。

---

## 1. 总览

Paperico macOS 是一个**独立 SwiftUI 应用**（无 Python 后端依赖）：把 PDF 论文经 MinerU 解析为结构化段落，用一次流式 LLM 请求完成全文翻译 + 要点 + 方法索引，再提供双语精读、证据问答、批注与笔记导出。全部数据（论文、对话、笔记、批注、解析产物）持久化在沙盒内的 `Application Support/Paperico/`，配置存 UserDefaults，两个密钥（LLM API Key、MinerU Token）存 Keychain。

- 技术栈：SwiftUI + @Observable（Swift 5）／AppKit（窗口、分割条、文本输入）／PDFKit（原稿阅读）／WKWebView（精读正文排版）／Foundation Networking（直连 MinerU 与 OpenAI 兼容 LLM）／Node + rolldown（仅用于预生成阅读器 JS bundle，App 构建不依赖 Node）。
- 目标平台：macOS 26.0+（Xcode 26+）；bundle id `com.paperico.native`；App 沙盒开启。
- 单窗口工作台：路由只有 5 个页面（首页 / 论文库 / 方法索引 / 设置 / 阅读器），导航守卫、浮层、菜单都挂在这一个窗口上。

### 1.1 分层架构

```mermaid
flowchart TD
    subgraph App 层["App/（启动、装配、路由、主题、窗口）"]
        PA[PapericoApp] --> RV[RootView] --> Pages
        AM[AppModel 组合根] --> AE[AppEnvironment 依赖注入]
    end
    subgraph Stores 层["Stores/（可观察状态）"]
        PS[PapersStore] ; PJ[ProjectsStore] ; RS[ReaderStore] ; CS[ChatStore] ; SS[SettingsStore]
    end
    subgraph Core 层["Core/（业务引擎，20 个文件）"]
        LIB[PaperLibrary actor<br/>library.json + 每论文 JSON] ; PP[PaperPipeline] ; MU[MinerUClient] ; AN[AnalysisEngine] ; LL[LLMClient] ; CH[ChatService]
    end
    Pages[Pages/ + Chat/ + Components/（SwiftUI 界面）] --> Stores 层
    Stores 层 --> Core 层
    PP --> MU ; PP --> AN ; AN --> LL ; CS --> CH ; CH --> AN
    subgraph 阅读器 Web 面["Resources/Reader（WKWebView 内容）"]
        RJ[reader.js（由 reader-renderer 生成）] ; RC[reader.css] ; IH[index.html] ; KX[KaTeX 字体与样式]
    end
    PDV[PaperDocumentView] <-->|window.paperico* / messageHandlers.reader| RJ
```

### 1.2 页面结构树（RootView → 页面 → 区域）

```
PapericoApp (App/PapericoApp.swift)   单窗口 Window("Paperico", id: "workspace")
└─ RootView (App/RootView.swift)      [.modifier(AppEnvironment) 注入全部依赖; .modifier(ReaderExitGuard)]
   ├─ startupView                     appModel.ready=false：加载中 / 失败重试
   ├─ routedPage（switch router.page）
   │  ├─ .home     → HomePage          hero + 指标条 + 最近阅读/工作流双卡 + 功能导览 + WorkspaceNav
   │  ├─ .library  → LibraryPage       项目侧栏 + 工具栏 + PaperCard 网格 + 上传 sheet + 拖拽分组
   │  │    └─ 浮层入口：处理任务 / 回收站 → router.libraryManagement
   │  ├─ .methods  → MethodsPage       类别侧栏 + MethodCard 网格 + 合并浮层
   │  ├─ .settings → SettingsPage      三 tab（AI 模型 / PDF 解析 / 阅读外观）+ 就绪清单 + 通知卡
   │  └─ .reader   → ReaderPage        阅读器外壳（加载/错误态、轮询、性能采样）
   │       ├─ ReadingArea              中央区：文本（WKWebView）⇄ PDF（PDFKit）+ 浮动工具条 + 进度条
   │       │    ├─ PaperDocumentView   文本精读 = WKWebView 加载 Resources/Reader/index.html
   │       │    ├─ PdfReadingArea      原生 PDFKit 阅读面 + 选区引用 + bbox 闪烁定位
   │       │    ├─ floatingTools       模式切换 / 双语 / 重译 / 进度环 / 缩放
   │       │    └─ processingStage / errorStage   处理中阶段导轨 / 出错重解析
   │       ├─ RightPanel               右侧浮动卡 = MetaCard（概览）+ ReaderDivider + ChatPanel（对话）
   │       ├─ resizeHandle             右缘拖拽调 RightPanel 宽（ReaderDivider）
   │       ├─ WorkspaceNav             左下导航（含"论文逻辑链"目录）
   │       └─ 抽屉模式                 窄窗下 RightPanel 滑入滑出 + 圆钮唤起
   ├─ WorkspaceMenuOverlay             WorkspaceNav 菜单真正的绘制层（RootView overlayPreferenceValue）
   └─ LibraryManagementOverlay         处理任务 / 回收站浮层（router.libraryManagement 非空时）
```

---

## 2. 目录总览

```
macos/
├── README.md                    构建运行说明、代码边界、数据与凭据（人工维护）
├── architecture.md              本文
├── Package.swift                SwiftPM 包（PapericoCore）：仅编译纯逻辑做 swift test，不含 UI
├── Paperico.xcodeproj/          Xcode 工程（文件系统同步组，增删 Swift 文件不用改 pbxproj）
├── Paperico/                    App 源码（Xcode target 的同步根目录）
│   ├── App/                     入口、装配、路由、主题、窗口 chrome（9 个文件）
│   ├── Models/                  Codable 数据传输类型 + 状态枚举（2 个文件）
│   ├── Stores/                  @Observable 状态层（5 个文件）
│   ├── Core/                    业务引擎：持久化、管线、网络客户端、纯函数（20 个文件）
│   ├── Support/                 路径、偏好、性能、导出、Markdown 解析缓存 + 配置 plist（7 文件 + 2 plist）
│   ├── Pages/                   5 个页面 + Reader/ 子目录（8 个文件）
│   ├── Chat/                    ChatPanel（对话/笔记面板）
│   ├── Components/              可复用控件与视觉系统（7 个文件）
│   ├── Resources/Reader/        打包进 App 的离线阅读器 web 资源（reader.js 为生成物）
│   ├── Assets.xcassets          AccentColor + PapericoMark（模板图）
│   └── paperico.icon            Xcode 26 Icon Composer 图标文档（编译为 paperico.icns）
├── reader-renderer/             阅读器 JS 的 Node 源码 + rolldown 打包脚本 + 测试
├── scripts/                     DMG 打包、API 契约检查、语法检查、性能基准（含 tests/）
├── Tests/                       MarkdownRenderingSmoke.swift + PapericoCoreTests/（17 个 XCTest）
├── build/                       本地产物（DMG、日志、DerivedData），不入库主体
└── .build/                      SwiftPM 构建缓存
```

---

## 3. 工程与配置文件

### `Package.swift`
SwiftPM 包定义（swift-tools-version 5.9），**只服务于核心测试**，不构建 App。包名 `PapericoCore`，平台 macOS 14+，零外部依赖。target 的 `path` 是整个 `Paperico/` 目录，但通过 `sources` 白名单只编译 21 个纯逻辑文件（`Models/Models.swift`、`Models/PaperStatus.swift`、`Support/AppPaths.swift` + `Core/` 下 18 个），`exclude` 排掉 UI/资源层与依赖 AppKit/UserDefaults/Keychain 的文件（`KeychainStore`、`PaperPipeline`、`LocalPrefs`、`PaperMarkdown`、`ReaderPerf`、`MarkdownExporter` 等）——这样 `swift test --package-path macos` 无需启动 SwiftUI 即可验证持久化/并发/归档/网络协议代码。testTarget 为 `PapericoCoreTests`。

### `Paperico.xcodeproj/project.pbxproj`
唯一 App target `Paperico` 的工程文件（objectVersion 77，Xcode 16+）：
- **文件系统同步组**：`PBXFileSystemSynchronizedRootGroup` 直接指向 `Paperico/` 目录，`Resources/` 显式为 folder reference。因此 `Resources/Reader/` 整目录自动作为 bundle 资源打包，增删 Swift 文件**不需要**重新生成 pbxproj。唯一例外：`Support/Info-extra.plist` 不进 target membership（作为 `INFOPLIST_FILE` 引用）。
- 关键构建设置：`PRODUCT_BUNDLE_IDENTIFIER = com.paperico.native`；`MACOSX_DEPLOYMENT_TARGET = 26.0`（target 层覆盖 project 层的 14.0）；`MARKETING_VERSION = 0.2.5`、`CURRENT_PROJECT_VERSION = 7`；`SWIFT_VERSION = 5.0`；`CODE_SIGN_STYLE = Automatic`；`CODE_SIGN_ENTITLEMENTS[sdk=macosx*] = Paperico/Support/Paperico.entitlements`；`GENERATE_INFOPLIST_FILE = YES` + `INFOPLIST_FILE = Paperico/Support/Info-extra.plist`；`ASSETCATALOG_COMPILER_APPICON_NAME = paperico`；`ENABLE_USER_SCRIPT_SANDBOXING = YES`。
- **没有任何 shell script 构建阶段**：Xcode 构建从不运行 `reader-renderer/bundle.mjs`；`reader.js` 是预生成并提交进仓库的。
- 无测试 target、无包依赖；测试走 SwiftPM（`swift test --package-path macos`），系统框架由 Swift `import` 自动链接。

### `Paperico/Support/Paperico.entitlements`
沙盒签名权限，共三条：`com.apple.security.app-sandbox`（沙盒——`AppPaths` 的容器路径成立的前提）、`com.apple.security.network.client`（作为客户端发起网络请求：MinerU/LLM）、`com.apple.security.files.user-selected.read-write`（保存面板自选位置写入，支撑 `MarkdownExporter`）。

### `Paperico/Support/Info-extra.plist`
补充 Info.plist（与 `GENERATE_INFOPLIST_FILE` 生成的内容叠加）：
- `NSAppTransportSecurity → NSAllowsLocalNetworking = true`：允许对本地服务的明文 HTTP（本地 MinerU Gradio、本机 LLM 服务）。
- `UTImportedTypeDeclarations`：`net.daringfireball.markdown`（conforms to `public.plain-text`，扩展名 md/markdown）——`MarkdownExporter` 里 `UTType(importedAs:)` 的声明来源。

### `Paperico/Assets.xcassets/`
- `AccentColor.colorset`：universal sRGB `#275DCE`（与 `reader.css` 的 `--accent` 同色；对应构建设置 `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`）。
- `PapericoMark.imageset`：`paperico-monotone.svg`，`template-rendering-intent: template`（单色模板图，WorkspaceNav 品牌钮用 accent 染色）。

### `Paperico/paperico.icon/`
Xcode 26 **Icon Composer** 图标文档（非传统 .appiconset）：`icon.json` 描述分层（`Untitled.svg` 蓝色渐变层 + `OO.svg` 灰色层，带阴影/半透明参数），构建时编译为 `paperico.icns` / `Assets.car`；`make_dmg.sh` 内嵌 python 会校验产物图标的完整性。`build/Paperico-*.sha256` 与 `build/Paperico-installed-before-*.zip` 是发版辅助产物。

---

## 4. App/ — 启动、装配、路由、主题、窗口

### `App/PapericoApp.swift`（86 行）
进程入口（`@main`）。声明唯一窗口 Scene `Window("Paperico", id: "workspace")`，内容为 `RootView().modifier(AppEnvironment(model: appModel))`；窗口修饰：`hiddenTitleBar`、min 490×560、默认 1360×860。
- `@NSApplicationDelegateAdaptor(PapericoAppDelegate.self)`——注意该 delegate 类**定义在** `Pages/Reader/ReaderExitGuard.swift`（用于退出时拦截未保存批注）。
- `ReaderAnnotationCommands`：接管菜单撤销/重做——非文本编辑态调 `readerStore.annotationDraft.undo()/redo()`，文本编辑态转发系统 `undo:`/`redo:`；⌘S 仅当 `hasUnsavedAnnotations` 时保存批注。
- `WorkspaceSettingsCommands`：菜单"设置…"⌘, → `router.go(.settings)` + `openWindow(id: "workspace")`（复用工作台窗口）。
- 自定义菜单"工作台"：⌘1/⌘2/⌘3 分别跳首页/论文库/方法索引。
- 通过 `FocusedValue`（`readerAnnotationStore`）拿到当前阅读页的 `ReaderStore`。

**UI 位置**：菜单栏（撤销/重做/保存、工作台菜单、设置…）+ 应用生命周期。

### `App/RootView.swift`（127 行）
根布局，全窗口内容的真正组装者：
- `!appModel.ready` 时显示启动页（"正在打开本地论文库…" / 失败 + "重新读取"按钮）；否则按 `router.page` 渲染 5 个 Page（`.transition(.opacity)`）。
- `.task { await appModel.bootstrap() }` 启动加载；`onAppear` 里同步 `systemIsDark`、`AppBootstrap.install()`、`applyWindowChrome()`。
- `.overlayPreferenceValue(WorkspaceMenuPreferenceKey)` 渲染 `WorkspaceMenuOverlay`（WorkspaceNav 菜单的绘制层）；`.overlay` 渲染 `LibraryManagementOverlay`（打开时下层页面 disabled）。
- 注入环境：`\.containerWidth`、`\.trafficLightClearance`（= `WindowChrome.topClearance`）；macOS 上 `.ignoresSafeArea(.container, edges: .top)`（标题栏隐藏后高度统一交给 WindowChrome 管）。
- 挂载 `ReaderExitGuard`、`focusedSceneValue(\.readerAnnotationStore, …)`（仅 `.reader` 页面时非 nil）。
- 主题切换动画：palette 变化时全局 0.2s 交叉淡化。

### `App/Router.swift`（31 行）
`@MainActor @Observable` 导航状态。`enum Page { home, library, methods, settings, reader(paperId: String) }`；
- `go(_:)` 先过 `navigationGuard`（由 `ReaderExitGuard` 注册，拦截有未保存批注的跳转），通过后清 `libraryManagement` 浮层并切页；`goWithoutGuard(_:)` 是守卫放行后的实际跳转。
- `libraryManagement: LibraryManagementSheet.Section?`（`tasks` 处理任务 / `trash` 回收站）驱动全屏管理浮层。
- `lastPaperId` 读写 `LocalPrefs`（键 `"paperico:last-paper"`），供 WorkspaceNav"继续上次阅读"。

### `App/AppModel.swift`（99 行）
**组合根**。`init()` 依次创建 `PaperLibrary` → `SettingsStore` → `PaperPipeline(library:settings:)` → `Router` → `AppStore(settingsStore:)` → `ProjectsStore` → `PapersStore(library:pipeline:)` → `ReaderStore(library:)` → `ChatStore(library:settings:)` → `AppServices`；并把 `settingsStore.onSettingsApplied` 接到 `appStore.syncFromSettings()`（外观一次性迁移）。
- `bootstrap()`：`AppBootstrap.install()` → `try await library.load()` → `ready = true` → `await settingsStore.fetch()`；失败写 `startupError`（`ApiFailure.wrap`）。
- `palette` 计算属性：`Palette.default(accentHex: appStore.accentColor, dark: …)`；`preferredScheme` 由 `appStore.theme` 推出。

### `App/AppEnvironment.swift`（24 行）
依赖注入 ViewModifier：把 AppModel 与全部 store（appStore/settingsStore/projectsStore/papersStore/readerStore/chatStore/router/services）挂到窗口内容树，另注入 `\.palette`、`\.backgroundOpacity`、`\.glassOpacity`、`.preferredColorScheme`、`.tint`。唯一调用方是 `PapericoApp`。

### `App/AppStore.swift`（67 行）
外观状态的可观察真身：`theme`（"light"/"dark"/"system"）、`accentColor`（默认 `#2F6FED`）、`backgroundTransparency`（0–50）、`glassTransparency`（0–30，默认 15）。全部持久化在 `LocalPrefs`（UserDefaults）；`syncFromSettings()` 仅在本地无值时从 `settingsStore.settings?.appearance` 迁移一次。
**UI 位置**：设置页"阅读外观"分区的绑定源；WorkspaceNav 右侧的明暗切换按钮（`setTheme`）；其值经 AppEnvironment 变成全局环境。

### `App/AppServices.swift`（15 行)
把 `PaperLibrary` + `PaperPipeline` 打包成一个 `@Observable` 注入环境（`@Environment(AppServices.self)`），让视图直接取用本地数据层与管线（MethodsPage、LibraryPage、LibraryManagementSheet、ReaderPage、ReadingArea、ChatPanel 都用它）。

### `App/Theme.swift`（226 行）
设计令牌层（文件名虽是 Theme，但没有叫 `Theme` 的类型）：
- `struct Palette`：18 个颜色令牌（accent / accentSoft / accentFaint / appBase / amber / success / danger / gray0…gray900），`defaultLight`（accent 回退 `#275DCE`）/ `defaultDark`（accent 与 `#f4f6fa` 按 0.82 混合提亮）。
- `\.palette` 环境键；`Color` 扩展：`init?(hex:)`、`mix(with:ratio:)`、`chipBackground()`、`relativeLuminance`（WCAG）、`contrastingForeground`（对比度≥3:1 选白/黑）、`isLight`。
- `Font.reading(_:)`：衬线正文（系统 New York）。
- `enum MethodCategory`：方法索引的 8 个类别（`ML_MODEL 机器学习模型` / `ALGORITHM 算法` / `INSTRUMENT_METHOD 表征检测` / `DATASET_BENCHMARK 数据集基准` / `METRIC 评价指标` / `CHEMISTRY 反应试剂` / `SOFTWARE_TOOL 软件` / `OTHER`）及各自颜色——只被 MethodsPage 使用。

**UI 位置**：无独立 UI，视觉上处处生效（全部配色、状态色、方法分类色、衬线字体）。

### `App/WindowChrome.swift`（71 行，macOS 部分）
无标题栏窗口画布的单一管理点：`topClearance = 30`（红绿灯下的内容顶部留白，经 `\.trafficLightClearance` 下发，HomePage/WorkspaceNav 消费，ReaderPage 重置为 0）；`apply(to:baseColor:opacity:)` 设置 `.fullSizeContentView`、透明标题栏、主题背景色（`isOpaque` 随透明度、`isMovableByWindowBackground`）、阴影；`applyToAll` 遍历所有应用窗口。RootView 在主题/透明度变化时重刷。

---

## 5. Models/ — 数据传输类型

### `Models/Models.swift`（335 行）
全部 Codable DTO，decoder 用 `.convertFromSnakeCase` 镜像后端 schema。按域分组：
- **库与项目**：`ProjectGroup`（分组）；`PaperListItem`（论文列表项：title/titleZh/authors/year/domainTags/status/projectId/sourceType/originalFileName/lastOpenedAt/tldr/narrativeSummary/contributions/difficultyEstimate/venue/errorMessage/errorCode…；计算属性 `statusEnum`、`displayTitle`——title 空回退 originalFileName 再回退"未命名论文"）。
- **解析块**：`Block`（order/kind/pageIdx/`bbox: [Double]?`（MinerU 页内归一化 0–1000）/sectionTitle/textOriginal/textZh/oneLiner/keywords/roleInNarrative/imagePath/captionOriginal/captionZh/figureType/coreTakeaways/dataReadingNotes/tableHtml/latex/plainExplanation/entityRefs/headingLevel）——全应用最核心的结构。
- **方法实体**：`MethodEntity`（canonicalKey/name/category/definitionZh/blockRefs）；`PaperDetail`（paper + blocks + entities）；`PaperStatusOut`（轻量状态，轮询用）。
- **对话**：`ChatMessage`（含 `generationState: String?` = stopped|failed，旧数据可缺省）、`ChatSession`、`AttachedContextType`（`text_selection`/`method_card`/`figure`/`preset_prompt`，`init(raw:)` 容错）、`AttachedContext`（手写解码）。
- **笔记**：`Note`。
- **设置**：`ModelProfile`/`ModelProfileCreate`（baseUrl/apiKey(Masked)/model/temperature/maxTokens/reasoningEffort/streaming）、`MinerUSettings`/`MinerUDefaultOptions`（is_ocr/enable_formula/enable_table/model_backend，手写 lenient 编解码）、`AppearanceSettings`、`PresetPrompt`、`ChatDefaults`、`ProfileAssignment`（translationAndExtraction/logicChainAndSummary/figureVision/chat/noteSynthesis 五角色）、`AppSettings`、`TestConnectionResult`。
- **方法索引**：`MethodIndexItem`（id = canonicalKey + papers: [MethodIndexPaper] + addedAt，手写 snake_case 解码）。

**被谁使用**：几乎全部层；上表每个类型的使用方见各 Core/Stores/Pages 文件。

### `Models/PaperStatus.swift`（39 行）
论文处理状态枚举，全应用状态文案的唯一来源：
`uploaded(待解析) → parsing(解析中) → parsed(已解析) → normalizing(清洗中) → analyzing(分析中) → reducing(归纳中，旧管线遗留枚举值) → ready(已就绪)`，另有 `error(出错)`、`unknown`。
- `init(raw:)` 未知字符串回退 `.unknown`；`processingCopy` 给 ReadingArea 的准备阶段文案（如 `.parsing → "MinerU 正在恢复版面结构"`）；`isActive` = 非 ready 且非 error（轮询判断依据）。
**UI 位置**：LibraryPage/HomePage 的状态点与状态文字、阅读页阶段导轨、处理任务面板。

---

## 6. Support/ — 路径、偏好、性能、导出、Markdown 缓存

### `Support/AppPaths.swift`（33 行）
标准用户数据目录：`appSupport` = `Application Support/Paperico/`（沙盒下实际为 `~/Library/Containers/com.paperico.native/Data/Library/Application Support/Paperico/`，也是 `PaperLibrary` 的数据根）；`logs` = `appSupport/logs`（perf-summary.log）。`install()` 幂等建目录。

### `Support/AppBootstrap.swift`（16 行)
进程级一次性初始化开关，目前只调 `AppPaths.install()`。调用方：`AppModel.bootstrap()` 与 `RootView.onAppear`。

### `Support/LocalPrefs.swift`（116 行）
全部 UserDefaults 偏好的唯一读写层（键名沿用 web 版 localStorage）。完整键清单：
- `paperico:last-paper`（最后阅读的论文 id）
- `paperico:left-width` / `paperico:right-width`（阅读页逻辑链栏 / 右侧卡宽）
- 每论文：`paperico:reader-mode:<id>`（text/pdf）、`paperico:text-progress:<id>`、`paperico:pdf-progress:<id>`、`paperico:pdf-zoom:<id>`
- 外观：`paperico:appearance-accent`、`paperico:appearance-theme`、`paperico:appearance-font-size`、`paperico:background-transparency`（clamp 0–50）、`paperico:glass-transparency`（默认 15，clamp 0–30）

调用方：Router、AppStore、SettingsStore、SettingsPage、ReaderPage、ReadingArea、PdfReadingArea。

### `Support/PaperMarkdown.swift`（392 行）
Markdown 渲染性能层——从 `MarkdownText.body` 抽出的行级解析 + AttributedString 构建，带**两级 NSCache**（原实现每帧重复解析是阅读页卡顿主因）：
- `MarkdownBlock` 枚举：heading/paragraph/code/quote/unordered/ordered/mathDisplay/table/rule 九种块。
- `blocks(for:)` 行状态机解析（``` 围栏、`$$…$$` 公式、标题层级、引用、表格、分隔线、有序/无序列表、段落聚合），缓存上限 1500 块。
- `attributedString(markdown:fontSize:codeBackground:…)` 用 `AttributedString(markdown: .inlineOnlyPreservingWhitespace)` 渲染行内样式，缓存上限 2000。
- `InlineMathSplitter`：正则把 `$x$` 行内公式转为行内代码样式（避免不完整 KaTeX）。
**被谁使用**：`MarkdownText`（聊天消息渲染）、`ReaderStore`（切论文时 `clearCache()`）、`ReaderPerf.dumpSummary`（缓存命中率统计）、性能基准脚本。

### `Support/MarkdownExporter.swift`（31 行）
笔记导出：`export(_ note:)` 弹原生 NSSavePanel（默认文件名 = 笔记标题，UTI `net.daringfireball.markdown`），`startAccessingSecurityScopedResource` + 原子写入用户自选位置。**UI 位置**：ChatPanel 的"下载最近笔记"按钮。

### `Support/ReaderPerf.swift`（121 行）
阅读页性能追踪（默认关闭，`PAPERICO_PERF=1` 或 UserDefaults `paperico:perf-trace` 开启）：os_signpost 区间计时、`task_vm_info` 内存 footprint、`PaperMarkdown` 两级缓存命中统计；`dumpSummary()` 追加到 `AppPaths.logs/perf-summary.log`（>2MB 重建）。调用方：`ReaderStore`（fetchPaper/refreshPaper 区间）、`ReaderPage`（open 区间 + 每 4s dump）。
（注意：文件内注释给的 defaults domain `com.paperico.Paperico` 与实际 bundle id `com.paperico.native` 不一致，以 bundle id 为准。）

---

## 7. Stores/ — 可观察状态层

组合关系：全部由 `AppModel` 构造并经 `AppEnvironment` 注入环境，视图用 `@Environment(X.self)` 取用。

### `Stores/PapersStore.swift`（70 行）
论文库列表状态：`papers: [PaperListItem]` + `filter`（projectId/q）+ loading/error。
- `fetch`（listPapers）、`upload(fileData:fileName:projectId:)`（→ `library.importPDF` 后 `pipeline.startProcessing`）、`movePapers`（批量移动分组）、`renamePaper`、`deletePaper`（先 `pipeline.cancel` 再软删除）、`setFilter`。
**UI 位置**：LibraryPage（网格/搜索/上传/CRUD）、HomePage（统计与最近阅读）、LibraryManagementSheet（操作后刷新）。

### `Stores/ProjectsStore.swift`（38 行）
项目分组状态：`projects: [ProjectGroup]`；`fetch` / `create` / `renameProject` / `deleteProject`（删除分组但论文脱钩不删）。
**UI 位置**：HomePage（项目计数）、LibraryPage 侧栏与移动菜单。

### `Stores/ReaderStore.swift`（239 行）
阅读器核心状态（注释"mirrors useReaderStore"）：
- 论文详情：`paper: PaperDetail?`；`fetchPaper(id:)` 用 `readerRequestVersion` 防竞态，并行拉 detail + annotations，切换时 `PaperMarkdown.clearCache()`；`refreshPaper`（只换 paper，处理中阶段变化时用）；`applyStatus(_:)`（轮询时轻量更新 status，避免整篇重建）。
- 阅读状态：`bilingualMode`（original/translation/bilingual，默认 bilingual）、`fontSize`（13–23）、`activeBlockId`、`highlightedEntities`、`viewMode`（.text/.pdf）、`pendingScrollTarget`/`pendingPdfFocus`（文本跳转 vs PDF bbox 闪烁定位，token 递增保证重复点击也生效）。
- **批注草稿**：`annotationDraft: ReaderAnnotationDraft`（撤销/重做状态机）；`stageAnnotation → commitPendingAnnotation`（field 限 title/note）；`hasUnsavedAnnotations` 驱动退出守卫与 ⌘S；`saveAnnotations()` → `library.saveReaderAnnotations`。
- **附加上下文**：`attachedContext: [AttachedContext]`（选中文本/图/方法卡进对话）；`outlineEntries`（`PaperOutline.entries` + 节点批注标题覆盖）。
**UI 位置**：ReaderPage、ReadingArea、PaperDocumentView 桥、RightPanel/MetaCard、ChatPanel（scrollToBlock/attachedContext）、WorkspaceNav 目录、菜单命令（⌘Z/⌘⇧Z/⌘S）。

### `Stores/ChatStore.swift`（194 行）
单篇论文的对话会话状态（注释"mirrors useChatStore"）：`sessions` / `currentSession` / `streaming` / `preparingRevision`（合成 `busy`）/ `streamContent`（流式增量）/ `pendingMessage`；`requestVersion: UUID` 防止切论文后旧请求回写。
- `bind(to paperId:)` 切论文清状态；`sendMessage` 走 `ChatService.send` 的 AsyncThrowingStream（消费 content/sessionId/sessionTitle），结束后从 `library.chatSession` 重载权威数据；`stopGenerating`（停止按钮/Esc）；`editAndResend` / `regenerate` 用 `ChatRevision` 算出修订 Turn，新建"· 修订"分支会话后重走 sendMessage；`newSession` / `loadSession` / `fetchSessions`。
- LLM 配置来自 `settingsStore.llmConfig(for: .chat)`。
**UI 位置**：ChatPanel（唯一重度消费者）、ReaderPage（bind/fetchSessions）。

### `Stores/SettingsStore.swift`（268 行）
原生双 Key 配置：**UserDefaults 存配置、Keychain 存密钥**。`llmProfile: LLMProfileConfig`（temperature 0.3 / maxTokens 8192 / reasoningEffort "medium" / streaming true）与 `mineruConfig: MinerUConfigCore`（mode "cloud"、baseUrl `https://mineru.net/api/v4`、localUrl `http://127.0.0.1:7860`）分别存于键 `paperico:llm-profile` / `paperico:mineru-config`。
- `synthesized: AppSettings` 把本地配置合成完整视图模型（apiKey 掩码前 4 后 4；五角色全指 "primary"；`ChatDefaults.defaultPresetPrompts` 六条预设提问）。
- `readSavedCredentials`（Keychain 非交互读，锁定账户记 `credentialsNeedAuthorization`）、`saveLLMProfile` / `saveMinerU`（ServiceURL 校验 + `KeychainStore.write`）、`llmConfig(for:)` / `mineruClientConfig()` 供管线与对话取用、`testLLM` / `testMinerU` 连通性测试。
**UI 位置**：SettingsPage 三个 tab 的表单来源与保存目标；ChatPanel（presetPrompts、notes 角色 LLM）；PaperPipeline（构造注入）。

---

## 8. Core/ — 业务引擎（20 个文件）

按职能分四组解读。**这组文件同时被 SwiftPM 测试覆盖（`Tests/PapericoCoreTests/`），是包 `PapericoCore` 的内容**。

### A. 数据持久层

#### `Core/PaperLibrary.swift`（560 行）
本地论文库 **actor**——替代原 FastAPI 后端的持久层，串行化所有事务。
- `LibraryLayout`（非隔离，视图可同步取 URL）：`pdfURL(id) = root/pdfs/<id>.pdf`、`paperDir(id) = root/papers/<id>/`（blocks.json / entities.json / chat.json / notes.json / reader-annotations.json）、`mineruOutputDir(id) = root/mineru_output/<id>/`、`analysesDir(id) = root/analyses/<id>/`、`fileURL(forRelativePath:)`（拒绝路径穿越/符号链接逃逸）。root 默认 `AppPaths.appSupport`。
- `load()`：读 library.json + **启动对账**——status ∈ {parsing, parsed, normalizing, analyzing, reducing} 的论文改为 error（`INTERRUPTED_BY_RESTART`，"处理在应用退出时被中断"）。
- `persistIndex()`：原子写；失败回滚内存 index（`committedIndex` 快照）。
- `importPDF`：`.pdf` 后缀 + `%PDF-` 魔数校验 + **SHA256 去重**（命中活跃论文/回收站分别报错，`DUPLICATE_PAPER`）；`importSourceURL`（URL 导入，暂无 UI）。
- 项目 CRUD（paperCount 动态算；删组=论文脱钩）；`listPapers`（项目/状态/关键词过滤）、`paperDetail`（读 blocks+entities，反推 entityRefs，markOpened 更新 lastOpenedAt）。
- **回收站**：`deletePaper` = 软删除（记录进 `index.trash`，全部产物保留）；`restorePaper`（项目已删则脱钩；active 状态恢复为 error/CANCELLED）；`permanentlyDeletePaper`（先确认索引可写，再删 pdfs/papers/mineru_output/analyses 四处，任一失败保留 trash 可重试）。
- **跨论文方法索引**：`methodIndex`（沿 `methodAliases` 链分组全部论文的 entities，跳过 hiddenMethods）/ `editMethod` / `deleteMethod` / `mergeMethods`。
- 会话/笔记/批注：`chatSessions` / `chatSession` / `saveChatSession`（新会话插头部）、`notes` / `addNote`、`readerAnnotations` / `saveReaderAnnotations`（保存时按合法 block id 过滤空值）、`writeAnalysisRaw`（analyses sidecar）。
- 工具：`newId()` = UUID 前 12 位小写 hex；`blockId(paperId:order:)` = `b<前6位>-<四位序号>`（对话引用 `[b00xx]` 的来源）；`now()` = RFC3339 UTC 毫秒；`canonicalKey(_:)` = lowercase + 非 `[a-z0-9一-鿿]` 归一为 `_`。
**被谁使用**：AppModel/AppServices 装配；五个 Store 全部读写；ChatService、PaperPipeline、MinerUClient（now()）；测试 LibraryTests/MethodIndexTests/ChatServiceTests/ReaderAnnotationTests。

#### `Core/LibraryIndex.swift`（52 行）
`library.json` 的 Codable schema（v1）：`projects` / `papers`（必需，缺失视为损坏）/ `shaByPaperId` / `sourceUrlByPaperId` / `trash: [TrashedPaper]` / `methodContent`（用户覆写的方法名/类目/定义）/ `methodAliases`（合并映射）/ `hiddenMethods` / `methodAddedAt`。`schemaVersion != 1` 抛"论文库由更新版本创建"。只被 PaperLibrary 使用。

#### `Core/LibraryFiles.swift`（31 行）
原子 IO 原语：`readJSON` / `writeJSON` / `writeJSONAny`（JSONSerialization + prettyPrinted + sortedKeys）/ `writeData`（`.atomic` + 自动建父目录）。**约定只能在 PaperLibrary actor 内调用**——读、改、原子写之间无挂起点，防止并发导入/聊天保存互相覆盖。失败抛 `STORAGE_FAILED` 并保留原文件。

### B. 处理管线与并发

#### `Core/PaperPipeline.swift`（398 行）
`@MainActor @Observable` 的管线编排：MinerU 解析 → 规范化为 Block → 单次全文分析 → 持久化。可观察状态 `failures` / `progress` / `cloudStates` / `nodeProgress`（如 "全文翻译与分析：x / y 个节点"）。
- 入口：`startProcessing`（.full）、`reparse`（强制新任务）、`retranslate`（复用 blocks 只重跑分析）、`recoverAnalysis`（本地恢复已返回的模型输出，零模型调用）、`cancel`；`spawn` 先 cancel 旧任务并 await，generation id 防旧任务回写。
- 并发闸门：`mineruGate = JobGate(limit: 2)`、`llmGate = JobGate(limit: 2)`（云端只把**提交段**放进闸门，排队不占许可）。
- `runFullPipeline` 四阶段：① `waitForCredentials`（200ms 轮询 Keychain 凭据就绪）→ ② 解析（`findContentList` 命中则复用；否则 status=parsing，cloud 走 `MinerUClient.runFullPipeline`（`waitForQueuedTask: true`），local 走 `runLocalPipeline`）→ ③ 规范化（`parseContentList` → `PaperLibrary.blockId` → `writeBlocks`）→ ④ `runAnalysis`（llmGate 内，`AnalysisEngine.analyzePaper` 流式，`capture` 持续覆写 `analyses/<id>/single_pass.json`）→ `saveAnalysis`（methods→MethodEntity；figure/table 写 captionZh/coreTakeaways；equation 写 plainExplanation；其余写 textZh；全部写 oneLiner/roleInNarrative/entityRefs；回写论文元数据）→ status=ready。
- 失败统一 `recordFailure`：取消 → `CANCELLED`；否则 `ApiFailure.wrap` 文案（截 500 字）+ 具体 `ErrorCode`。
- `runRecovery`：读 `single_pass.json` 的 `raw_response`，用 `input_fingerprint`（SHA256）校验原文未变后本地 `decodePaperResponse`。
**UI 位置**：LibraryPage（状态标签、4s 轮询）、ReaderPage（3.5s 轻量轮询 status→applyStatus/refreshPaper）、LibraryManagementSheet（开始处理/重试/重新解析/重新翻译/恢复结果/停止）、ReadingArea（重译进度、重解析按钮）。

#### `Core/JobGate.swift`（46 行）
FIFO 并发闸门 actor：`acquire` / `release` / `withPermit`；被取消的任务从等待队列摘除并 resume CancellationError，不泄漏许可。被 PaperPipeline 使用；JobGateTests 覆盖（16 任务峰值并发=2、取消不占坑、抛错释放）。

### C. MinerU 解析客户端

#### `Core/MinerUClient.swift`（678 行）
MinerU 云端（mineru.net）与本地 Gradio 两种部署的解析客户端（移植 backend `mineru.py`）：提交 → 轮询 → 下载 ZIP → 进程内解包 → 定位/解析 content_list.json。
- **云端流程**：`POST {base}/file-urls/batch`（payload 含 `files[].data_id = "paperico-<12hex>"`、is_ocr、enable_formula/enable_table、model_version）→ `PUT` 签名 OSS URL（**不带** Authorization/Content-Type，否则 403 SignatureDoesNotMatch）→ 轮询 `GET /extract-results/batch/{batchId}`（`state`: waiting-file/uploading/pending/running/converting/done/failed；`full_zip_url`、`err_msg`、`extract_progress`、`trace_id`）；URL 导入走 `POST /extract/task` + `GET /extract/task/{taskId}`。
- **轮询与断点**：`pollInterval = 3s`（pending 时 max 15s）；`waitForResult` 双任务竞速（轮询 vs `maxWait = 600s`，且超时预算从**进入 running/converting 的时刻**起算——排队时间不扣）；pending 超时且 `waitForQueuedTask` 时每 15s 继续轮询**同一任务**（不重传）。`cloud-task.json` 存 `{baseURL, options, submitted, completed}` 断点（配置匹配时"继续已有任务"）；每次轮询写 `cloud-status.json` 诊断（state/trace_id，无 token）。
- **下载解包**：`downloadAndExtractResults`——ZIP 下到 `mineru_output/<id>/.incoming-<UUID>/`，`ZipArchive.extract` 解包，`findContentList` 定位 content_list（优先 `latest-content-list.txt` 指向的最新一次；否则按路径深度+名称取最浅，排除 `_content_list_v2.json`），改名 `result-<UUID>/`。
- **本地 Gradio**（默认 `http://127.0.0.1:7860`）：`POST /gradio_api/upload`（multipart）→ `POST /gradio_api/call/convert_to_markdown_stream`（data 参数含 end_pages=1000、语言标签、backend `vlm→vlm-engine`）→ `GET .../{event_id}`（SSE，`complete` 事件取结果 ZIP URL）→ 同上解包。
- **`parseContentList(at:dataRoot:)`**：content_list.json 必须是数组；忽略 header/footer/page_number/aside_text 与 `ref_text`；类型映射 `title|text_level>0 → section_heading`（记 heading_level）、`image|chart → figure`、`table → table`（table_body→table_html）、`equation → equation`（latex）、`list → list_item`、其余 → paragraph；`img_path` 折叠为相对 dataRoot 的 `image_path`；输出块含 order/kind/section_title/text_original/caption_original/image_path/table_html/latex/page_idx/heading_level/bbox。
- `testMinerU`：local `GET /gradio_api/info`（检查 `/convert_to_markdown_stream` 端点）；cloud `GET /extract/task/__paperico_connection_test__`（401/403 或业务码 A0202/A0211 判认证失败）。
**被谁使用**：PaperPipeline（解析阶段）、SettingsStore（testMinerU）；MinerUPollingTests / MinerUUploadTests。

### D. LLM 与分析

#### `Core/LLMClient.swift`（397 行）
OpenAI-compatible Chat Completions 客户端（移植 backend `llm.py`）+ `LLMProbe` 探测。
- `normalizeBaseURL`：容忍直接粘贴 `/chat/completions` 端点；`makeRequest`：`POST {base}/chat/completions`，Bearer 认证。
- `stream(...)`：SSE 逐行解析（`data:` 前缀、`[DONE]` 结束、`choices[0].delta.content`），`finish_reason=="length"` 抛截断错误；**400 兼容重试**最多 3 次——错误含 `max_completion_tokens` 则改名参数、含 `temperature` 则删参（`compatiblePayload`）。`chat(...)` 非流式聚合；`response(...)` 统一消费接口。
- `LLMProbe.testLLM`：探测连通性 + 是否支持 `reasoning_effort` + `modelCapacity`（`GET /models` 白名单键里找 max output tokens），返回 `TestConnectionResult`。
**被谁使用**：AnalysisEngine（chat/stream/modelCapacity）、ChatService（response）、SettingsStore（normalizeBaseURL/testLLM）；LLMCompatibilityTests。

#### `Core/AnalysisEngine.swift`（446 行）
MinerU 解析完成后的"**单次全文分析**"引擎：一次流式 LLM 请求同时生成全文译文、段落要点、逻辑角色、全文总结与方法索引。
- `paperAnalysisPrompt`：要求模型只输出紧凑 JSON `{"paper":{title,title_zh,tldr,narrative_summary,contributions,domain_tags,difficulty_estimate}, "methods":[…], "nodes":[{id,zh,note,role}]}`，nodes 与输入一一对应同序。
- `analyzePaper`：blocks 精简为 `{id,kind,text,section?,latex?,table_html?}`；**非 body 区块本地生成空记录不进模型请求**（`PaperContentScope`）；`LLMProbe.modelCapacity` 探测输出上限并估算 `outputBudget`；Kimi 系 host 强制 `reasoningEffort="none"`；流式（timeout 600s、无兼容性重试）逐 chunk 喂 `JSONObjectStream`（按大括号深度/引号状态切出完整顶层对象），每收到新 id 回调 `progress`，每 ≥5s `capture` 一次诊断日志；最后 `decodePaperResponse` 严格校验节点 id 序列一致 + `validatePaperAnalysis`（body 非公式节点 zh 非空、note/role 必须含中文、methods refs ⊆ body id）——任一失败抛 `JSON_PARSE_FAILED`，**不自动重试**（但部分响应已被 capture 保存，可用 recoverAnalysis 本地恢复）。
- `inputFingerprint`：输入 `.sortedKeys` JSON 的 SHA256（恢复时校验原文未变）。
- `buildChatSystemPrompt`：对话系统提示词（简中回答、禁止编造、`[b00xx]` 引用、`$…$` 公式）。
- `synthesizeNote` + `noteSynthesisPrompt`：笔记合成（Obsidian 风格 Markdown、YAML frontmatter、`[[双链]]`）。
**被谁使用**：PaperPipeline（分析阶段）、ChatService（system prompt/笔记）；AnalysisRecoveryTests、ChatServiceTests。

#### `Core/ServiceURL.swift`（14 行）
`endpoint(base:path:)`：trim、去尾 `/`、拼 path，scheme 必须 http/https、host 非空，否则抛"服务地址无效"。被 LLMProbe、MinerUClient、SettingsStore 使用。

#### `Core/ServiceErrors.swift`（99 行)
稳定错误码体系（与 backend status.py 同名同义）：`ErrorCode` 14 个——`MINERU_NOT_CONFIGURED / MINERU_TIMEOUT / MINERU_SUBMIT_FAILED / MINERU_PARSE_FAILED / LLM_NOT_CONFIGURED / LLM_CALL_FAILED / JSON_PARSE_FAILED / PDF_MISSING / PARSE_EMPTY / INTERRUPTED_BY_RESTART / INTERNAL / STORAGE_FAILED / DUPLICATE_PAPER / CANCELLED`。三种领域错误 `PipelineError`（message+code）/ `MinerUServiceError`（多 lastState，供超时后续等判断）/ `LLMServiceError`；UI 包装 `ApiFailure`（network/timeout/api）由 `ApiFailure.wrap` 统一成展示文案。errorCode 会持久化进 library.json 的论文记录。被几乎所有层使用。

#### `Core/KeychainStore.swift`（66 行）
Keychain 读写封装：service 固定 `"com.paperico.native"`，两个 generic password 条目——account `llm.api-key`（LLM API Key）与 `mineru.token`（MinerU Token），`kSecAttrAccessibleAfterFirstUnlock`。读分交互/非交互（`kSecUseAuthenticationUIFail` 不弹授权窗，`needsAuthorization` 上报 UI）；写采用 update-first、空值删除。只被 SettingsStore 使用。

### E. 对话子系统

#### `Core/ChatService.swift`（318 行）
对话与笔记服务（移植 backend chat.py/notes.py），**会话持久化的唯一 owner**。
- `send(...) -> AsyncThrowingStream<StreamEvent>`：`ensureSession` → user 消息先落盘 `papers/<id>/chat.json` → system prompt = `AnalysisEngine.buildChatSystemPrompt` + `ChatContextBuilder.buildPaperContext`（逻辑链 ≤6000 字符 + 方法索引 top40）；首轮追加 `<paperico-title>` 标题输出指令；有附加上下文再追加 `buildAttachedText`（总上限 18000 字符）→ `LLMClient.response` 流式 → 逐 chunk 过 `ChatTitleDecoder` 剥标题信封 → 结束/异常都构造 assistant 消息：`citedBlockIds = extractBlockRefs`（正则抓 `[...]`，仅保留合法 block id）；异常时 `generationState="stopped"/"failed"` 并在新 Task 里保存部分回答。
- `ChatTitleDecoder`：跨 chunk 的 `<paperico-title>…</paperico-title>` 剥离状态机（≤512 字节缓冲；流中断时若 buffer 仍像标题开头则丢弃，防元数据泄漏为答案）。
- `synthesizeNote`：按 messageIds 收集选中消息 + `logic_chain`/`method_index` 结构化上下文 + paperMeta → `AnalysisEngine.synthesizeNote` → 无 frontmatter 则补 YAML 头 → `library.addNote`。
**UI 位置**：ChatStore（send/edit/regenerate 全走它）、ChatPanel（笔记工具条）；ChatServiceTests。

#### `Core/ChatContextBuilder.swift`（137 行）
对话上下文分层压缩（逐字移植 backend context.py）：`compactLogicChain`（按 roleInNarrative 分组 `角色 · [b00xx] 一句话`，超 6000 字符删行但无条件保留章节标题）、`compactMethodIndex`（按引用数降序 top40，单方法最多 12 refs）、`buildAttachedText`（text_selection 截 6000 / method_card / figure 截 400，总 18000）、`buildPaperContext`。只被 ChatService 使用；ChatContextTests 覆盖限额。

#### `Core/ChatRevision.swift`（20 行)
编辑/重新生成消息时计算"从哪一轮重建"的纯函数：`editing`（截断历史到被编辑 user 消息之前，保留其 attachedContext）、`regenerating`（找到 assistant 前最后一条 user）。返回 `Turn(history, content, context)`，原始会话保留、从选中轮次重发成"· 修订"分支。被 ChatStore 使用。

### F. 阅读器纯函数

#### `Core/PaperContentScope.swift`（92 行）
判定每个解析块属于 frontMatter / body / backMatter（出版元信息、参考文献等**排除出翻译与逻辑链**，但不删块、不改 id）：abstract/introduction 定起点（Nature 类无 Abstract 标题时找首个 ≥220 字符实质段落）、backMatter 标签集（references/致谢/作者贡献/数据可用性/利益冲突/funding…）定终点、`isMetadata` 6 条正则（DOI/收稿日期/通讯作者/机构行/作者行/.pdf 文件名）。被 AnalysisEngine、PaperOutline、PaperDocumentView 使用。

#### `Core/PaperOutline.swift`（76 行）
从 blocks 构建阅读器大纲（只含 body 区块）：`PaperOutlineEntry(blockId/level/heading/title/parentBlockId)`；为旧库推断层级（`#` 数量或 `1.2.3` 编号深度；扁平解析器的 researchSections 恢复为 level 1）；段落/证据挂到最近章节（level = 父+1）。被 ReaderStore（outlineEntries）、MetaCard（节点计数）、PaperDocumentView（outline_entries 注入 web）使用。

#### `Core/ReaderAnnotations.swift`（40 行）
阅读器用户批注的内存草稿状态机：`ReaderNodeAnnotation(title/note)` + `ReaderAnnotationDraft`（`values` 字典 + undo/redo 双栈各上限 100 + `isDirty`/`didSave`/`discard`）。被 ReaderStore（annotationDraft）、PapericoApp（菜单撤销/重做）使用；持久化经 PaperLibrary 落 `papers/<id>/reader-annotations.json`。

#### `Core/DocumentProgress.swift`（24 行）
`PDFReadingPosition(pageIndex, fraction)`：0–100 进度 ⇄ 页码+页内比例 互转（NaN/负值/越界钳制）。被 PdfReadingArea 使用。

#### `Core/MarkdownTable.swift`（10 行）
Markdown/HTML 表格的矩形快照：把参差行补齐成等宽（短行尾补空串），含流式渲染中的不完整行（防越界崩溃回归）。被 MarkdownText 使用。

#### `Core/ZipArchive.swift`（225 行)
最小进程内 ZIP 解包器（沙盒内无法调 `/usr/bin/unzip`）：解析中央目录逐条解压；支持 stored(0)/deflate(8)（Compression framework raw deflate），自建 crc32 表校验；**安全约束**：拒绝路径穿越/绝对路径/反斜杠/符号链接逃逸（逐级祖先检查 + resolvingSymlinksInPath 前缀校验）、加密与 zip64、单条 256MB/总量 1GB 上限。被 MinerUClient 使用；ZipArchiveTests 覆盖全部截断/穿越/CRC 情形。

---

## 9. Pages/ — 页面层

### `Pages/HomePage.swift`（432 行）—— 首页
`ScrollView > GlassEffectContainer > VStack`，内容宽 ≤1240，左下挂 `WorkspaceNav`；`.task` 拉 papers + projects。
- `hero`：kicker "PAPER READING WORKBENCH"、大标题"读懂论文，让判断有据可循。"、两个按钮（"打开论文库"→`.library`、"检查 API 配置"→`.settings`）+ 右侧纯装饰 `OrbitArt`（旋转白卡片 + accent 圆点 + "结构化精读"贴纸）。
- `metrics`：三格统计（篇论文 / 已完成解析 / 个研究项目）。
- `lowerGrid`（自定义 `HomeCardRow: Layout` 等高双卡）：**继续阅读**（最近 4 篇：序号 + 标题 + 状态副文案 + StatusDot + 箭头，点击 `router.go(.reader(paperId:))`）与 **WORKFLOW**（01 文件拆解 / 02 提炼逻辑 / 03 证据问答）。
- `featureGuide`：双语精读 / 顺着逻辑读 / 答案回到证据 三特性 + 新手提示。
依赖：PapersStore、ProjectsStore、Router、WorkspaceNav、GlassKit、Icons、Controls。

### `Pages/LibraryPage.swift`（996 行）—— 论文库页（最大的页面文件）
`WorkspaceSplitLayout { 项目侧栏 } content: { 主列 }`；`.task` 每 4s 轮询（有 active 论文时 fetch）。
- **侧栏**："项目分组" + 新建（TextField 表单）+ "全部论文"行 + 每个项目行（色点 + 名称 + 计数 + hover 重命名/删除钮；macOS 上 `ProjectDropDelegate` 接收论文拖入）。
- **工具栏**："LIBRARY / 论文库" 标题、状态筛选（全部状态/待解析/已就绪/…/出错）与排序（最近添加/标题/年份/状态）两个 `PillIconMenu`、`PillSearchField`；第二行动作：**上传论文**（fileImporter 选 PDF → `papersStore.upload`；未配置管线时提示"去设置"）、选择模式、"处理任务"/"回收站"按钮（设 `router.libraryManagement`）。
- **选择栏**：全选、已选计数、`PillPicker` 移动目标、移动/删除。
- **内容区**：错误条 / SkeletonCard×3 / 空态 / `paperGrid`（LazyVGrid adaptive 360 的 `PaperCard`：标题 + 中文副行 + 作者/年份/项目胶囊 + 领域标签 chips + StatusDot + 右上 hover 操作（选择/重命名/删除）+ `.onDrag` 输出 paper-id + 右键菜单）。卡片点击 → `router.go(.reader(paperId:))`。
- 三个 `.alert`：删除论文（软删除）/ 删除项目 / 批量删除。
依赖：PapersStore、ProjectsStore、AppServices.pipeline、Router、Controls 全家桶、Icons、GlassKit。

### `Pages/LibraryManagementSheet.swift`（182 行）—— 处理任务 / 回收站浮层
**不是** sheet/新窗口，是工作区视图树内的模态块；由 RootView 在 `router.libraryManagement` 非 nil 时 overlay 显示（`LibraryManagementOverlay`：`OutsideDismissArea` + 居中 760×600 面板，Esc 关闭）。
- `Section.tasks`：每 2s 轮询全部论文的待处理任务；每行显示标题、`pipeline.statusLabel`（含"云端排队中"）、进度、错误；操作：打开（跳阅读器）、停止（`pipeline.cancel`）、或 `Menu`（label"开始处理/重试"）四项——继续处理（复用已有结果）/ 重新解析 PDF / 重新翻译已有段落 / 恢复上次返回结果（不调用模型）。
- `Section.trash`：回收站列表（"移入时间：YYYY-MM-DD"）；恢复（`library.restorePaper`）/ 永久删除（内联确认 → `pipeline.cancel` + `library.permanentlyDeletePaper`）。
依赖：AppServices（library + pipeline 全套）、PapersStore/ProjectsStore（操作后刷新）、Router。

### `Pages/MethodsPage.swift`（485 行）—— 方法索引页
`WorkspaceSplitLayout { 实体类别侧栏 } content: { 主列 }`；数据来自 `services.library.methodIndex()`。
- **侧栏**：8 个 `MethodCategory` 类别行（色点 + 名称 + 计数）+ "全部方法"。
- **主列**：排序（首字母 / 最近添加）+ `PillSearchField`；选择模式（"选择两个方法进行合并" → `ToolbarButton("合并")`）；内容区 LazyVGrid adaptive 280 的 `MethodCard`（名称 + definitionZh + 类别胶囊 + "N 篇论文"；展开后列出每篇论文的行按钮跳 `router.go(.reader(paperId:))`；可编辑名称与说明）。
- **合并浮层** `MethodMergePanel`：两条方法编号列表 + `SlidingChoice` 三选（保留第一个 / 保留第二个 / 重新编写，切换回填名称与说明）+ 合并后名称/说明 + 提交（`library.mergeMethods`）。
依赖：AppServices.library、Router、MethodCategory、Controls、GlassKit。

### `Pages/SettingsPage.swift`（808 行）—— 设置页
`WorkspaceSplitLayout { tab 侧栏 } content: { 表单卡 }` + 右下角通知卡 overlay。
- **侧栏**：三个 tab（AI 模型 / PDF 解析 / 阅读外观，各带 label/description/icon）+ 底部"使用前置条件"就绪清单（"AI 模型"/"PDF 解析"三态：已就绪/待配置/无法确认）。
- **AI 模型 tab**：配置名称、模型名称、Base URL、API Key（`FormSecretField` 显隐切换）+ "测试连通性"、思考强度 `ReasoningSlider`（off/low/medium/high）、输出上限 `FormStepper`。**门控**：连接三项与最近一次成功测试一致才解锁思考强度/输出上限（测试返回的 `reasoningLevels`/`defaultMaxOutputTokens` 存 `llmCaps`）。
- **PDF 解析 tab**：解析方式 `SlidingChoice`（MinerU 云端 API / 本地部署 Gradio）；cloud 显示 Base URL + MinerU Token + 测试连接，local 显示本地服务地址 + 测试连接；解析模型（local: Pipeline/VLM/Hybrid；cloud: VLM 推荐/Pipeline）；公式识别/表格识别/强制 OCR 三个 Toggle。
- **阅读外观 tab**：主题（亮色/暗色/跟随系统）、正文字号 13–23、背景透明度 Slider 0–50、强调色（12 预设色块 + ColorPicker + hex 输入，绑定 `appStore`）、玻璃透明度 Slider 0–30。
- 保存：`saveLLM` → `settingsStore.saveLLMProfile`、`saveMinerU` → `settingsStore.saveMinerU`、`saveAppearance` → `appStore.setAccent/setTheme` + `LocalPrefs.readingFontSize`；Keychain 授权提示条（"读取已保存凭据"按钮）。
依赖：SettingsStore、AppStore、LocalPrefs、Controls（SlidingChoice/FormSecretField/ReasoningStepper…）。

### `Pages/Reader/` — 阅读器（8 个文件）

#### `ReaderPage.swift`（213 行）—— 阅读器外壳
三态：loading（"正在打开论文工作台…"）/ 错误（重新载入 + 返回论文库）/ `desktopReader`。
- **任务**：`.task(id: paperId)` bootstrap（`chatStore.bind` → 写 `LocalPrefs.lastPaperId` → `readerStore.fetchPaper` → `chatStore.fetchSessions`）；`.task` 每 **3.5s** 轮询 `pipeline.status`——同阶段只 `applyStatus` 轻量更新，阶段变化才 `refreshPaper`（避免 180+ block 整篇重建卡顿）；perfLoop 每 4s dump（默认关）。
- **布局**（`GeometryReader > ZStack(alignment: .trailing)`）：① `ReadingArea`（右侧 padding 让位）；② 抽屉态 `OutsideDismissArea`；③ `RightPanel` **常驻挂载**（注释：保持卡片与 chat 状态），inline 或 `offset` 滑入的抽屉两种呈现；④ 右缘 `resizeHandle`（`ReaderDivider`，`rightWidth` 夹 310…520，写 `LocalPrefs.rightWidth`）。
- **宽度自适应**：`floatingPanelsFit`（≥ max(900, 左栏+500+右栏+24)）时右侧卡常驻 inline；否则右下角出现"打开论文信息与对话"圆钮唤起抽屉；窄窗下新增附加上下文自动弹抽屉。左下 `WorkspaceNav(currentPaperId:, includesDirectory: true)`（含"论文逻辑链"目录菜单）。

#### `PaperDocumentView.swift`（306 行）—— 文本精读的 WKWebView 承载
**原生侧拥有数据、导航与持久化；web 侧只管排版**。加载 `Bundle.main` 的 `Resources/Reader/index.html`（`loadFileURL`，只开放该子目录）。
- `PaperWebSurface: NSViewRepresentable` 建 `AnnotationWebView: WKWebView`（非持久 dataStore、透明背景、`userContentController.add(coordinator, name: "reader")`、`setURLSchemeHandler(PaperImageSchemeHandler, forURLScheme: "paperico-image")`）。
- **Swift → JS**：`window.papericoLoad(payload)`（全量装载：snake_case JSON + annotations + progress + `excluded_block_ids`（`PaperContentScope` 非 body 区块）+ `outline_entries`（`PaperOutline`））、`papericoAnnotations`、`papericoStyle`（palette 20 个色值转 rgba + fontSize/mode/outlineWidth，合并节流）、`papericoJump(id, centered)`、`papericoClearSelection()`、`papericoFormatNodeNote(key)`（⌘B/⌘I/⌘H 由 `AnnotationWebView.performKeyEquivalent` 拦截转发）。
- **JS → Swift**（每条消息带 paperId 校验）：`loaded` / `progress`（进度+最近 blockId）/ `jump` / `selectionChanged`（选区 rect → 原生浮钮定位）/ `annotation`（draft/commit/cancel 三阶段 → ReaderStore 草稿）/ `annotationFocus` / `figure` / `entity`（→ `addAttachedContext`）。用户点 http/https/mailto 外链交 `NSWorkspace.open`。
- `PaperImageSchemeHandler`：`paperico-image://block/<blockId>` 白名单式本地图片加载（仅本篇已校验 URL，按扩展名回 png/jpeg mime）。
- overlay：`SelectionActionOverlay`（选区上方/下方浮出"加入论文对话"圆钮）。
**UI 位置**：仅 ReadingArea 的文本模式。

#### `ReadingArea.swift`（468 行）—— 阅读器中央区
`ZStack(alignment: .top)`：文本模式 `textReadingScroll` ⇄ PDF 模式 `PdfReadingArea`（`pdfVisited` 后懒挂载、保持存活只切可见性）+ 右上浮动工具 + 底部 2pt accent 阅读进度条。
- **floatingTools 五件套**：① 文本/PDF 模式切换（写 `LocalPrefs.setReaderMode` + `readerStore.setViewMode`）；② 双语切换（original ⇄ bilingual；PDF 模式禁用）；③ 重新翻译（alert 确认 → `pipeline.retranslate`，进行中显示进度与计时）；④ 进度环 + 百分比；⑤ 缩放组（PDF 改 `pdfZoom` ±0.1（0.6…2.4），文本改 `readerStore.setFontSize`）。
- **textReadingScroll**：`PaperDocumentView` 全参数回调桥（onAnnotation → stageAnnotation 三阶段；onProgress → 防抖 0.6s 写 `LocalPrefs.setTextProgress` + `setActiveBlock`；onAttach/onJump）；左缘 `outlineResizeHandle`（`leftWidth` 夹 190…390，写 `LocalPrefs.leftWidth`）。
- **阶段页**：status==.error → `errorStage`（"PROCESSING STOPPED" + errorCode chip + 红框错误 + "重新解析" → `pipeline.reparse`）；处理中 → `processingStage`（"PREPARING PAPER" + `statusEnum.processingCopy` 文案 + 四点 `stageRail` 阶段导轨 + "可以留在此页…"）。

#### `PdfReadingArea.swift`（527 行）—— 原生 PDFKit 阅读面
替代 web 版 pdf.js：连续单页滚动、每篇缩放记忆、页内进度、原生选区引用、T2.3 块定位闪烁。
- `PlatformPdfView`（macOS `NSViewRepresentable` 包 `PDFView`，`.singlePageContinuous`、`autoScales=false`、透明背景）；`SharedPdfState`（选区/focus 状态）；`PdfCoordinatorBase: PDFViewDelegate`：页变化/选区变化/缩放通知 + 本地 `NSEvent` monitor 判定选区手势、`loadPaperIfNeeded`（后台读 `layout.pdfURL`，恢复进度）、`processPendingFocus`（按 `block.pageIdx` 跳页 + `block.bbox`（0–1000 坐标 y 翻转）加 1.8s accent 填充 `PDFAnnotation`——outline/对话证据/MetaCard 实体跳转的 PDF 入口）、`reportProgress`（`PDFReadingPosition` 折算）。
- 选区 overlay：`SelectionActionOverlay`（snippet 格式 `"P<page> · 文本"` → `readerStore.addAttachedContext(type: "text_selection")`）。

#### `RightPanel.swift`（35 行）—— 右侧浮动卡容器
垂直 `VStack`：`MetaCard`（上，高度可拖）+ `ReaderDivider(axis: .vertical)` + `ChatPanel`（下，占余高）；整体 `liquidPanel()` + `floatingSurface` 环境；顶部高度夹 100…stackHeight−250。仅出现在 ReaderPage。

#### `MetaCard.swift`（162 行)—— 论文概览卡
自上而下：标题（+中文副标题）→ 作者前 6（"等"）→ venue/year → 事实行（"N 分钟"按字符数/1100 估算、"N 节点"、难度估计）→ 领域标签 chips → **研究要点**（tldr，accent 竖线块）→ **全文主线**（narrativeSummary）→ **核心贡献**（编号列表）→ **方法与实体 chips**（前 18 个，点击 `highlightEntities` + `scrollToBlock(entity.blockRefs.first, centered: true)`——文本跳段 / PDF bbox 闪烁）。
另定义 `FlowChips` + `WrappingChipsLayout`（换行 chip 流式布局，被 MetaCard/ChatPanel/SettingsPage/PaperCard 复用）。

#### `ReaderDivider.swift`（72 行）—— AppKit 拖拽分割条
`NSViewRepresentable` 包 `DividerView: NSView`：**用屏幕坐标跟踪指针**（拖动不改变下次 drag 事件原点）；hover 才画居中小条；`resizeLeftRight`/`resizeUpDown` 光标；`mouseDragged` 回调 `onChange`（水平取 dx，垂直取 −dy），`mouseUp` 回调 `onEnd`；accessibility role `.splitter`。三处使用：ReaderPage 右缘（右卡宽）、RightPanel 中部（Meta/Chat 高度）、ReadingArea 左缘（逻辑链栏宽）。

#### `ReaderExitGuard.swift`（97 行）—— 退出守卫
挂在 RootView 上（全局一份），三条退出路径在"有未保存批注"（`readerStore.hasUnsavedAnnotations`）时统一弹同一 alert（"保存逻辑链与节点笔记的编辑？"：继续编辑 / 放弃编辑 / 保存并退出）：
1. 应用内导航：`onAppear` 向 Router 注册 `navigationGuard`；
2. 窗口关闭：`ReaderWindowCloseBridge`（NSViewRepresentable + Coordinator）把自己插为 `NSWindow.delegate` 拦 `windowShouldClose`（原 delegate 经 forwardingTarget 保留）；
3. 退出 App：`PapericoAppDelegate.applicationShouldTerminate`（由 PapericoApp 的 `@NSApplicationDelegateAdaptor` 安装）委派静态 `quitDecision`，返回 `.terminateLater`，确认后 `NSApp.reply(toApplicationShouldTerminate: true)`。

### `Chat/ChatPanel.swift`（553 行）—— 对话/笔记面板
仅出现在 RightPanel 下半部。`VStack { sessionBar; messagesList; attachedRow?; promptRow?; noteToolbar?; composer }` + 左上历史 overlay。
- **sessionBar**（44pt）：历史按钮（展开 ≤280 高的会话列表，点击 `loadSession`）、新对话、当前会话标题（≤40 字）、笔记导出钮（切 noteMode）。
- **messagesList**：空态引导；user 消息右对齐气泡（附 attachedContext 引文 chips）；assistant 消息用 `MarkdownText` 渲染 + **证据 chips**（`citedBlockIds`，点击 `readerStore.scrollToBlock(blockId, centered: true)` 回跳正文/PDF）+ "已停止生成"提示；每条消息操作：复制（NSPasteboard）/ 编辑并重新发送（user）/ 重新生成（assistant）/ 继续回答（stopped 时）；流式气泡（空显示"正在思考…"）；滚距底 >60 显示"回到最新回答"钮。
- **attachedRow**：当前附加上下文 chips（按 type 选 icon）+ 删除。
- **promptRow**：前 4 条预设提问（SettingsStore 六条默认：总结全文/总结方法/亮点与创新点/局限与未来方向/提取实验设置/生成自测思考题），点击填入输入框。
- **noteToolbar**（noteMode）：选择消息 → "生成笔记"（`ChatService.synthesizeNote`，notes 角色 LLM）/ "下载最近笔记"（`MarkdownExporter.export`）。
- **composer**：`MessageInput`（自适应高度 32–110）+ 发送/停止圆钮（⌘↩ 快捷键）。编辑态提示"编辑提问，原对话会保留"；发送前取走并清空 `readerStore.attachedContext`。
- Esc 优先级：关历史 → 停止生成；空文本 ↑ 召回上一问。

---

## 10. Components/ — 可复用控件与视觉系统

### `Components/GlassKit.swift`（213 行）
"液态玻璃"视觉系统核心：
- 常量与环境键：`CornerRadius`（card 20 / inset 12 / chip 8）、`\.backgroundOpacity`（默认 1）、`\.glassOpacity`（默认 0.85）、`\.floatingSurface`、`\.drawerSurface`、`\.containerWidth`（默认 1280，RootView 注入）、`LayoutBreakpoint`（reader 900 / settings 800 / workspace 760）。
- `GlassSurface`：macOS 26+ 用 `Color.clear.glassEffect(Glass)`，旧系统回退 `.regularMaterial`；`floatingSurface` 时垫 `.regularMaterial` + 白 overlay 保证遮挡后面文字；尊重 reduceTransparency。
- 修饰器：`View.liquidPanel()`（页面级 panel：侧栏、内容卡、首页面板、右侧卡）、`liquidInset()`（嵌套块）、`liquidTool()`（浮动工具小件）、`LiquidActionButtonStyle`（胶囊玻璃按钮，prominent 时 tint 玻璃 + 对比前景色）、`noFocusRing()`、`trafficLightTopPadding()`（红绿灯留白）。
**被谁使用**：几乎所有 UI 文件。

### `Components/Controls.swift`（410 行)
共享控件库（统一规格：高 38 胶囊，`ControlSpec.height = 38 / radius = 19`）：
- 导航/列表控件：`PillPicker`（下拉选择，LibraryPage 移动目标）、`PillSearchField`（搜索框，Library/Methods）、`PillIconButton`（38×38 圆形工具钮）、`PillIconMenu`（图标下拉菜单，状态/排序筛选）、`ToolbarButton`（primary/secondary/danger 三种胶囊动作钮，busy 显示 ProgressView——上传/移动/删除/保存配置/测试连通性等所有主行动）。
- 选区浮钮：`SelectionConversationButton`（"加入论文对话"玻璃圆钮）+ `SelectionActionOverlay`（定位到选区上方/下方，顶部避让 76pt）——被 PaperDocumentView 与 PdfReadingArea 复用。
- 表单控件：`FormTextField` / `FormStepper` / `FormSecretField`（显隐切换密钥）、`SlidingChoice`（matchedGeometryEffect 滑动分段选择）、`ReasoningSlider`（离散档位）。
- 辅助：`ScrollTitleFade`（滚动标题淡出 mask）、`CardCornerActions` / `CardCornerContentMask`（卡片右上 hover 操作组）。

### `Components/Icons.swift`（227 行）
Lucide → SF Symbol 图标体系：`enum Ic` 约 60 个静态图标常量（`symbol(_:fallback:)` 运行时检查存在性）；`Image.ic(_:)` 便捷构造；通用小部件：`SpinnerIcon`（加载占位）、`StatusDot`（状态点：ready→success、error→danger、unknown→gray、处理中→amber）、`SkeletonCard`（骨架屏）、`RoundIconButton`（32pt 圆形图标钮，symbolEffect 替换动画）、`PrimaryActionButton` / `SecondaryActionButton`（hero 与错误态大胶囊钮）。**被全部 UI 文件使用**。

### `Components/MarkdownText.swift`（281 行)
原生 Markdown 渲染器（替代 react-markdown + KaTeX），解析已抽到 `PaperMarkdown` 带缓存：heading（1.45/1.3/1.16/1.08 倍字号）/ paragraph（`PaperMarkdown.attributedString`，行内 `$…$` 以代码样式渲染）/ code 块（liquidInset）/ 引用 / 两种列表 / 块公式（纯文本 + 横向滚动）/ 表格（`NativeMarkdownTable` 网格）/ 分隔线。
- `HTMLTableParser`：HTML 表格 → `[[String]]`（正则 + 实体解码，NSCache 200 条），供 `PaperTableView`（**当前无 UI 调用方，表格渲染由 web 阅读器 surface 承担，此视图保留备用**）；性能基准脚本也调用它。
**当前唯一使用方**：ChatPanel（assistant 气泡与流式气泡）。

### `Components/MessageInput.swift`（100 行)
聊天输入框的 AppKit 桥（NSViewRepresentable 包 NSTextView）：**IME 安全**（有 marked text 时不拦截按键）；Return 发送 / Shift+Return 换行 / Esc 取消 / 空文本 ↑ 召回；`textDidChange` 测量高度回写 binding（自动增高 32–110）；手绘 placeholder。仅被 ChatPanel 使用。

### `Components/WorkspaceNav.swift`（373 行）—— 工作台导航
- `WorkspaceNav`：贴底左侧的导航条占位。本体只是 `Color.clear` 框，通过 `anchorPreference` 把锚点上抛——真正的 UI 由 RootView 的 `WorkspaceMenuOverlay` 在**所有内容层之上**绘制（玻璃菜单原地向上生长）。紧凑宽度（<760）收成 52pt 圆轨。
- `WorkspaceNavSurface`：品牌钮（`PapericoMark` 模板图）/ Paperico 品牌 + 下拉箭头 + 目录钮（仅阅读页）+ 明暗切换；`pages` 菜单：首页 / 论文库 / 方法索引 /（有 id 时）阅读器 / 设置，当前页标"当前"；`directory` 菜单："论文逻辑链 · N 个节点"，按 `entry.level` 缩进列出 outline 条目（heading 显示"第 N 页"），点击 `readerStore.scrollToBlock`，当前 `activeBlockId` 高亮。
- `WorkspaceSplitLayout`：Library/Methods/Settings 共用的桌面双列布局（左列放 sidebar + WorkspaceNav，右列 content；compact 时侧栏展开为浮层 + 内容 blur）。
- `OutsideDismissArea`：全屏透明 Button（真控件，避免无标题栏窗口背景拖拽吞点击），用于各浮层的点外关闭。
**被谁使用**：HomePage、ReaderPage（含目录）、WorkspaceSplitLayout（→ 三个页面）、RootView（overlay）。

### `Components/LocalPaperImage.swift`（59 行）
本地文件图片视图：`Task.detached` + `CGImageSourceCreateThumbnailAtIndex` 降采样至 1600px + NSCache（96MB/80 条，key 含文件修改时间）。三态：已加载 / 失败（"图像无法读取"）/ ProgressView。**当前代码库中无任何调用点**——文本正文的图片由 `PaperImageSchemeHandler` 在 WKWebView 内加载；属于备用组件。

---

## 11. Resources/Reader/ — 打包进 App 的离线阅读器 web 资源

被 `PaperDocumentView` 的 WKWebView 以 `loadFileURL` 加载；CSP 严格禁外连（`default-src 'none'; img-src paperico-image:; connect-src 'none'`），公式与排版全部离线。

| 文件 | 角色 |
|---|---|
| `index.html` | DOM 骨架：`<article id="paper">` 唯一容器 + `reader.css`/`katex.min.css` + `reader.js`；CSP 声明在此 |
| `reader.css` | 版式：CSS 变量（gray-0…900、`--accent:#275dce`、`--reading-size`、`--outline-width`）；衬线正文（Charter/Iowan/宋体）；两列 grid（逻辑链侧栏 + 正文）；`.outline` 节点轨道；双语开关（`[data-mode=original/translation]` 隐藏对应文本）；暗色主题；`.flash` 跳转高亮动画；页边批注编辑器样式 |
| `reader.js` | **生成物**（约 425 KB 压缩 IIFE）：全部渲染与桥接逻辑，见下 |
| `katex.min.css` + `fonts/`（20 个 KaTeX woff2） | KaTeX 0.16.47 离线数学排版 |
| `KaTeX-LICENSE.txt`、`THIRD-PARTY-NOTICES.txt` | 许可文件（bundle.mjs 自动生成/拷贝） |

**reader.js 的桥接协议**（由 `reader-renderer` 三个源文件生成）：
- Swift → JS：`window.papericoLoad(payload)`（全量装载）、`papericoAnnotations(next)`、`papericoStyle(next)`（保持滚动锚点不跳）、`papericoJump(id, centered)`（+ `.flash` 高亮）、`papericoClearSelection()`、`papericoFormatNodeNote(key)`。
- JS → Swift（唯一通道 `messageHandlers.reader.postMessage`，每条带 paperId）：`loaded`（节点数/公式数）、`progress`（0–100 + 最近 blockId，rAF+90ms 节流）、`selectionChanged`（blockId/snippet≤6000/rect；拖选松手才上报）、`jump`、`annotation`（field title/note × phase draft/commit/cancel）、`annotationFocus`、`figure`、`entity`。
- 渲染内容：标题区（RESEARCH ARTICLE + h1 + 中文标题 + 作者行）、逻辑链侧栏（OUTLINE 节点树 + 实体 chips + 页边批注编辑器）、正文按 kind 分支（section_heading / figure（`paperico-image://block/<id>` 图片 + 双语 caption + 图表要点）/ table（DOMParser 白名单清洗 table_html）/ equation（KaTeX）+ plainExplanation / 段落双语），页脚 END OF PAPER。

---

## 12. reader-renderer/ — 阅读器 JS 的 Node 源码与构建管线

**只负责** `PaperDocumentView` 的正文 + 逻辑链渲染；普通 Xcode 构建不需要 Node。

| 文件 | 角色 |
|---|---|
| `package.json` | `paperico-reader-renderer` v0.2.4；scripts：`build`（node bundle.mjs）、`test`（node --test）；固定精确版本依赖：katex 0.16.47、rehype-katex 7.0.1、remark-math 6.0.0、remark-parse 11、remark-rehype 11.1.2、unified 11.0.5；devDep rolldown 1.2.5 |
| `markdown.mjs`（82 行） | `renderMarkdown`：unified 管线（remarkParse → remarkMath → mhchem 化学式 → 自定义 sup/sub 与 `==高亮==` 插件 → remarkRehype → rehypeKatex）；`\[..\]`/`\(..\)` 分隔符归一为 `$$..$$`/`$..$`；`escapeHTML`；安全序列化——原始 HTML 永不执行、img 只输出 alt、丢弃 on*/src/id 属性与不安全 href（仅 https:/mailto:/# 放行） |
| `reader.mjs`（225 行） | 浏览器入口：DOM 构建（`rich`/`safeTable`/`outline`/`content`）、滚动进度（最近块锚定 y=25% 视口）、选区上报（pointerdown→up 间抑制）、样式应用（保持滚动锚点）、6 个 `window.paperico*` 入口与事件监听。无导出（IIFE 用） |
| `annotations.mjs`（82 行） | 页边批注编辑器：两个按钮（编辑逻辑链/写节点笔记）→ `.node-edit-box` textarea；每次 input 发 `annotation(draft)`、Enter commit、Escape cancel；`Cmd+B/I/H` 用 `wrapSelection` 包 `**`/`*`/`==`；同屏只允许一个编辑器（经 `window.papericoFinishAnnotation` 切节点先 commit） |
| `bundle.mjs`（34 行） | **构建脚本**：rolldown 把 `reader.mjs` 打成 minified IIFE 写到 `../Paperico/Resources/Reader/reader.js`；从 katex 包拷贝 `katex.min.css`、20 个 woff2、LICENSE；扫描 bundle 实际包含的 node_modules 生成 `THIRD-PARTY-NOTICES.txt`（缺 license 直接抛错，remark-math/rehype-katex 用 `licenses/remark-math-MIT.txt` 补） |
| `markdown.test.mjs`（8 例） | 上标/下标保留、行内公式 MathML、aligned+\tag、`\(\)`分隔符、化学式 `\ce{}`、script/img/onerror 注入被拒、外链图片与 javascript: href 被拒 |
| `annotations.test.mjs`（5 例） | wrapSelection 保留 Unicode 选区与嵌套格式、代码内高亮不生效、节点切换 commit、过期 close 不清新编辑器 |
| `selection.test.mjs`（2 例) | 拖选松手才上报、键盘选区即时上报、resize 移动浮钮、pointercancel/blur 无残留 |
| `README.md` / `licenses/remark-math-MIT.txt` | 边界说明 / 补丁许可证 |

**生成链与运行时机**：改 JS 后在 `reader-renderer` 里 `npm ci && npm test && npm run build` → bundle.mjs 直接覆盖 `Resources/Reader/reader.js` 并同步 KaTeX 资源与许可文件。**只手动或 CI 运行**——pbxproj 无 shell 阶段；CI 的 `reader` job（ubuntu/Node 22）构建后 `git diff --exit-code -- Resources/Reader` 强制生成物与仓库一致。改 `index.html`/`reader.css` 则直接编辑（非生成物）。

---

## 13. scripts/ — 工具链

| 脚本 | 功能 |
|---|---|
| `make_dmg.sh`（67 行） | Release 打包：从 pbxproj 提取 `MARKETING_VERSION` → `xcodebuild clean build`（DEVELOPER_DIR 自动指 Xcode，不改系统 xcode-select）→ 内嵌 python 校验图标产物（icon.json 层文件、Info.plist 的 CFBundleIconName、paperico.icns/Assets.car）→ 可选 `codesign --deep --options runtime`（设 `PAPERICO_SIGN_IDENTITY` 时；公证自行完成）→ `hdiutil create UDZO` → 输出 `build/Paperico-<version>.dmg`。CI 用 `CODE_SIGNING_ALLOWED=NO` |
| `check_api_contract.py`（149 行） | 防"后端 OpenAPI 与 Swift `Models.swift` DTO 漂移"：内置 14 个 schema 快照（ProjectOut/PaperListItem/BlockOut/…/MethodIndexItem）+ `AppSettingsOut` 五字段严格双向比较（`$ref`/`allOf` 递归解析）；字段 REMOVED/ADDED 都报 "API CONTRACT DRIFT DETECTED" exit 1。CLI：`--base`（默认 `http://127.0.0.1:8000` 拉 /openapi.json）/ `--file`（如 `backend/tests/openapi_snapshot.json`）/ `--update` |
| `check_swift_syntax.py`（59 行） | tree-sitter + tree_sitter_swift 解析 `Paperico/` 全部 .swift 找 ERROR/is_missing 节点（无 Apple 工具链的 Linux 环境用），只做语法级校验 |
| `typecheck_no_macros.sh`（7 行） | 兼容入口：直接 `exec script/build_and_run.sh --build-only` 走真实 Xcode 构建（注释：宏替身证明不了 app 能构建） |
| `run_reader_bench.sh` + `reader_perf_bench.swift`（216 行） | **历史原生 Markdown 渲染器**的性能基准（不测当前 WKWebView 文档面）：从后端拉一篇论文详情 → `xcrun swiftc -O` 把真实 App 源码（PaperMarkdown/MarkdownText/Theme 等）编成 CLI `readerbench` → 输出 JSON 解码耗时、缓存前后 body 求值提速倍数、滚动单帧成本与理论 FPS、内存 footprint。不落盘不改文件 |
| `tests/test_check_api_contract.py` | 快照必须过 + `--update` 打印新字段 + REMOVED/ADDED 检测 + `AppSettingsUpdate` 冒充不算数 |
| `tests/test_run_reader_bench.py` | 合成数据跑通；假 xcrun 编译失败（exit 91）时旧二进制**绝不能**被运行；4 组 xcode-select/DEVELOPER_DIR 组合不覆盖用户选择 |

---

## 14. Tests/ — 测试

### `Tests/MarkdownRenderingSmoke.swift`（47 行）
非 XCTest 的 `@main` 冒烟程序（由 `script/check_markdown_rendering.sh` 编译运行）：把真实 `MarkdownText` 放进隐藏 NSHostingView，对一个含残缺行的中文表格逐前缀（"流式"快照）在 220/330/480 三个宽度重渲染，断言高度有限，最后出位图——验证流式表格渲染不越界不崩溃。

### `Tests/PapericoCoreTests/`（17 个 XCTest 文件，`@testable import PapericoCore`，`swift test --package-path macos` 运行）

| 测试文件 | 被测对象 | 覆盖要点 |
|---|---|---|
| `LibraryTests.swift` | PaperLibrary / LibraryLayout | 搜索过滤；30 并发导入；SHA 去重（含回收站命中）；回收站保留产物/恢复清空已删项目/阻止迟到写入；永久删除可重导；损坏或未来 schema 的 library.json 不被覆盖；写失败回滚内存；符号链接与路径穿越被拒 |
| `AnalysisRecoveryTests.swift` | AnalysisEngine | JSONObjectStream 切分（代码围栏/转义引号）；本地容错恢复不捏造字段；inputFingerprint 键序无关；单次流式覆盖全部节点且进度递增；References 仅本地；max_tokens 取 provider 上限；401 不重试；length 截断报错；捏造 method refs 报无效引用 |
| `ChatServiceTests.swift` | ChatService / ChatTitleDecoder | `<paperico-title>` 跨 chunk 解码；标题仅首轮并持久化；停止生成保存部分回答（stopped）；完成流只持久化一次；未配置 LLM 报 llmNotConfigured |
| `ChatContextTests.swift` | ChatContextBuilder | 证据预览带出；多选区总上下文 ≤ 18000 预算 |
| `ChatRevisionTests.swift` | ChatRevision | editing 保留前序轮次与证据；regenerating 定位 user 轮；禁止编辑助手消息；旧数据缺 generationState 可解码 |
| `MinerUPollingTests.swift` | MinerUClient | 慢请求计入 deadline；畸形响应报 mineruParseFailed；超时重试复用同一 batch；强制重解析清 checkpoint；latest-content-list.txt 指向最新下载；排队 pending 不重传 |
| `MinerUUploadTests.swift` | MinerUClient.submitBatch | API 调用带 Bearer + JSON 头；签名 PUT **不得**带 Content-Type/Authorization（防 403） |
| `ZipArchiveTests.swift` | ZipArchive | stored/deflate；全部截断前缀抛错；路径穿越/绝对路径/符号链接逃逸/CRC 不符拒绝 |
| `JobGateTests.swift` | JobGate | 峰值并发=2；排队中取消不占坑；抛错释放许可 |
| `MethodIndexTests.swift` | PaperLibrary 方法索引 | 编辑名持久化可搜；merge 双向并集 refs；delete 隐藏别名；非法操作不改索引；写失败回滚 |
| `PaperOutlineTests.swift` | PaperOutline | 章节/小节/证据层级与 parent；旧 Markdown 层级解析；缺 headingLevel 可解码；扁平研究标题恢复层级 |
| `PaperContentScopeTests.swift` | PaperContentScope | 摘要边界前后弃 frontMatter/backMatter；无标签摘要；行内"摘要："与参考文献边界 |
| `ReaderAnnotationTests.swift` | ReaderAnnotationDraft + sidecar | undo/redo/discard 保持已存版本；didSave 不误标新编辑；sidecar 删除恢复后存活、剔除 unknown block |
| `DocumentProgressTests.swift` | PDFReadingPosition | 折算/往返/钳制 |
| `MarkdownTableTests.swift` | MarkdownTable | 短流式行补齐（旧越界崩溃回归）；超出列数不丢行 |
| `LLMCompatibilityTests.swift` | LLMClient | max_tokens→max_completion_tokens 降级；temperature 二次移除；401 不触发重试；粘贴端点归一化 |
| `ServiceURLTests.swift` | ServiceURL | 规范化与非法 base 抛错 |

---

## 15. 关键数据流（端到端）

1. **导入 → 解析 → 分析 → 就绪**：LibraryPage 上传 → `PapersStore.upload` → `PaperLibrary.importPDF`（SHA256 去重，status=uploaded）→ `PaperPipeline.startProcessing` → waitForCredentials → 复用或 `MinerUClient` 提交/轮询/下载/解包（status=parsing）→ `parseContentList` 规范化为 Block（status=parsed→normalizing）→ `AnalysisEngine.analyzePaper` 单次流式请求（status=analyzing，进度逐节点回传）→ `saveAnalysis`（status=ready）。失败 `recordFailure`（error + errorCode）。LibraryPage 每 4s、ReaderPage 每 3.5s 轮询驱动 UI。
2. **精读**：ReaderPage → ReadingArea → `PaperDocumentView` 把 `PaperDetail`（+批注+进度+excluded_block_ids+outline）注入 WKWebView → reader.js 渲染双语正文/逻辑链/KaTeX → 滚动/选区/批注/实体点击经 `messageHandlers.reader` 回到 ReaderStore。
3. **批注**：web 编辑器 draft/commit/cancel → `ReaderStore.stageAnnotation` → `annotationDraft`（脏标记驱动退出守卫与 ⌘S）→ `saveAnnotations` → `papers/<id>/reader-annotations.json`。
4. **证据问答**：正文选区/图片/实体 → `attachedContext` → ChatPanel 发送 → `ChatStore.sendMessage` → `ChatService.send`（压缩逻辑链 6000 + 方法索引 top40 + 附加上下文 18000 拼进 system prompt）→ LLM 流式 → 证据 chips `[b00xx]` 回跳（文本 scrollIntoView / PDF bbox 闪烁）→ 会话落盘 `chat.json`。
5. **笔记**：ChatPanel 选择消息 → `ChatService.synthesizeNote` → YAML frontmatter Markdown → `notes.json` → `MarkdownExporter` 导出 .md。

## 16. 持久化全景

```
~/Library/Containers/com.paperico.native/Data/Library/Application Support/Paperico/
├── library.json                  # LibraryIndex v1：项目/论文/SHA/回收站/方法索引用户编辑
├── logs/perf-summary.log         # ReaderPerf 性能摘要（>2MB 重建）
├── pdfs/<id>.pdf
├── papers/<id>/{blocks,entities,chat,notes,reader-annotations}.json
├── mineru_output/<id>/{cloud-task.json, cloud-status.json, latest-content-list.txt, result-<UUID>/}
└── analyses/<id>/single_pass.json  # LLM 原始响应 sidecar（诊断 + 断点恢复）

UserDefaults（com.paperico.native，LocalPrefs 统一管理）：
  paperico:last-paper · paperico:left-width · paperico:right-width
  paperico:reader-mode|text-progress|pdf-progress|pdf-zoom:<paperId>
  paperico:appearance-accent · appearance-theme · appearance-font-size
  paperico:background-transparency · glass-transparency · paperico:perf-trace
  paperico:llm-profile · paperico:mineru-config

Keychain（service "com.paperico.native"）：account llm.api-key · mineru.token
```

## 17. 构建 / 测试 / 打包速查

```bash
./script/build_and_run.sh                  # 构建+启动（仓库根；产物 build/DerivedData-Local/…/Paperico.app）
./script/build_and_run.sh --build-only     # 仅构建（typecheck_no_macros.sh 的真实实现）
./script/check.sh [--with-backend]         # python 工具测试 + swift test + Markdown 冒烟 + 构建
swift test --package-path macos            # 仅核心测试（PapericoCore）
./script/check_markdown_rendering.sh       # SwiftUI 表格渲染冒烟
cd macos/reader-renderer && npm ci && npm test && npm run build   # 改阅读器 JS 后重新生成 reader.js
./macos/scripts/make_dmg.sh [签名参数]      # 打包 DMG → macos/build/Paperico-0.2.5.dmg
```

## 18. 已知边界与注意点

- `macos/README.md` 开头写的版本是 0.2.4，pbxproj 的 `MARKETING_VERSION` 已是 0.2.5（README 略滞后）。
- `Support/ReaderPerf.swift` 注释里的 defaults domain `com.paperico.Paperico` 与实际 bundle id `com.paperico.native` 不一致，开启性能日志请用后者。
- `Components/LocalPaperImage.swift` 与 `MarkdownText.swift` 内的 `PaperTableView` 目前无调用方（备用/历史组件）；`PaperLibrary.importSourceURL` 暂无 UI 入口。
- `Models.swift` 的 DTO 与旧 FastAPI 后端 schema 保持兼容维护（`scripts/check_api_contract.py` 防漂移），但 App 运行本身不依赖后端。
- `PaperStatus.reducing` 是旧多阶段管线遗留枚举值，现仅出现在启动中断对账与状态文案表里。

## 19. v0.3.0：MCP 与发布扩展

- `MCP/Package.swift`：独立 PapericoMCP 包，锁定官方 Swift SDK 0.12.1；核心 target 仍不依赖 SDK。
- `MCP/Sources/PapericoMCP/ReadOnlyService.swift`：10 个只读工具、论文资源与 stateless HTTP 请求隔离。
- `MCP/Sources/PapericoMCP/LoopbackHTTPListener.swift`：127.0.0.1 监听、Bearer / Host / Origin 校验、大小与时间限制。
- `Paperico/Core/LibraryAutomation.swift`：SDK 无关的 actor 内查询，读取不更新最近打开时间，检查活动论文及图像路径。
- `Paperico/Stores/MCPStore.swift`：服务启停、随机 Token、Keychain 持久化、端口复用与客户端配置。AppModel 装配后通过 AppEnvironment 注入。
- SettingsPage 增加第 4 个「MCP 连接」tab；默认关闭，MCP 不触发解析、模型调用或数据修改。
- Keychain 增加 `mcp.access-token`，UserDefaults 增加 `paperico:mcp-enabled` 与 `paperico:mcp-port`。
- `Tests/PapericoMCPTests/`：真实 HTTP、安全边界、SDK 客户端互通及 Token 撤销测试。
- App 版本为 0.3.0 / build 8；DMG 打包保留 Sandbox 与 `network.server` entitlement，Release 工作流先执行回归测试。

使用方式与后续路线见 [MCP 文档](../docs/mcp.md)。
