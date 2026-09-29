# Paperico 原生 iOS/macOS App — 架构与 1:1 复刻映射

> 目标:将现有 Web UI(`frontend/src/`,React + Tailwind)与功能 **1:1 复刻**为原生 App,
> iOS 与 macOS 共用一套 SwiftUI 多平台工程,只用原生组件(URLSession / PDFKit / SwiftUI)。
>
> 工程位置:`ios/Paperico.xcodeproj` + `ios/Paperico/`(Swift 源码)。
> 后端**不做任何改动**:App 直接对话现有 FastAPI(`backend/app/main.py`,`/api/*`)。

---

## 1. 平台与形态

| 项 | 决定 |
|---|---|
| 框架 | SwiftUI + `@Observable`(Observation),无第三方依赖 |
| 部署目标 | iOS 17.0 / macOS 14.0(同一 target,`SUPPORTED_PLATFORMS = iphonesimulator iphoneos macosx`) |
| 响应式断点 | `horizontalSizeClass`:compact = Web ≤900/760px 分支(抽屉/页签);regular = 桌面三栏 |
| PDF | **PDFKit `PDFView`**(原生)替代 pdf.js canvas;缩放/进度/选择由 PDFKit 原生承担 |
| Markdown | 原生 `AttributedString(markdown:)` 分块渲染(见 §5 偏差) |
| 网络 | `URLSession`,Chat 用 `URLSession.bytes` 解析 SSE(与 `client.ts` 逐行语义一致) |
| 本地状态 | `localStorage` 同名键迁移到 `UserDefaults`(见 §4) |

## 2. Web → Swift 组件映射(1:1)

| Web (`frontend/src/`) | Swift (`ios/Paperico/`) | 说明 |
|---|---|---|
| `main.tsx` + `App.tsx` | `App/PapericoApp.swift` + `App/RootView.swift` | 根布局、路由页枚举、PageErrorBoundary→每页自带错误态 |
| `components/layout/TopBar.tsx` | `RootView` nav slot | home=72px 实底;workspace 页=浮动覆盖(0 高) |
| `layout/WorkspaceNav.tsx` | `Components/WorkspaceNav.swift` | 悬浮胶囊导航:品牌钮/明暗切换/目录开关/页面菜单(含 阅读器 项,last-paper) |
| `projects/HomePage.tsx` | `Pages/HomePage.swift` | hero 文案、orbit 装饰画(SwiftUI 图形重绘)、3 metrics、最近阅读、workflow 面板 |
| `projects/LibraryPage.tsx` | `Pages/LibraryPage.swift` | 项目侧栏(新建/重命名/删除/拖拽投递)、工具栏(搜索/状态/排序/选择/上传)、选择条(全选/移动/删除/完成)、卡片网格、内联重命名、上传弹层、4s 轮询 |
| `projects/MethodsPage.tsx` | `Pages/MethodsPage.swift` | 类别侧栏+计数、搜索、方法卡(展开论文列表) |
| `settings/SettingsPage.tsx` | `Pages/SettingsPage.swift` | 三分页侧栏+就绪度卡;LLM/MinerU/外观 三表单;测试连接;右下 notice;**新增:服务器地址**(原生客户端必需) |
| `reader/ReaderPage.tsx` | `Pages/Reader/ReaderPage.swift` | 桌面:中栏+8px 手柄+右栏(rightWidth 310–520,leftWidth 190–390 同约束);compact:顶部页签 逻辑链/正文/对话+徽标,visitedTabs 惰性挂载;3.5s 轮询 |
| `reader/ReadingArea.tsx` | `Pages/Reader/ReadingArea.swift` | 悬浮工具组(文本/PDF 切换、双语切换、重新翻译+后台错误回显、进度%、字号/缩放)、document-row 网格(margin 大纲+正文)、processing/error 舞台、文本进度恢复、active block 检测(目标线 = top+min(180, 25%)) |
| `reader/OutlineNode.tsx` | `Pages/Reader/OutlineNode.swift` | `getOutlineLevel` 正则级判定、SECTION/SUBSECTION/role 标签、实体 chips→附加上下文 |
| `reader/MobileOutline.tsx` | `Pages/Reader/MobileOutline.swift` | 全屏逻辑目录(左对齐变体) |
| `reader/MetaCard.tsx` | `Pages/Reader/MetaCard.swift` | 阅读时长(字数/1100)、节点数、难度、标签、tldr featured、主线、贡献、实体 chips(18)→高亮+跳转 |
| `reader/RightPanel.tsx` | `Pages/Reader/RightPanel.swift` | 信息/对话双卡+竖向拖拽分隔(48px 标题栏、最大化对置)、MobileSidePanel(DisclosureGroup) |
| `reader/PdfReadingArea.tsx` | `Pages/Reader/PdfReadingArea.swift` | PDFKit 版:连续滚动、0.6–2.4 缩放(按 paper 记忆)、进度按页恢复、选中文本→`加入论文对话` |
| `chat/ChatPanel.tsx` | `Chat/ChatPanel.swift` | 会话条(新对话/历史 Picker/笔记模式)、气泡(用户右 accent,助手灰+Markdown)、引用 chips(证据 xx→跳块)、流式气泡(正在思考…)、附加上下文 chips、预设提示词(前 4)、笔记工具条(生成笔记/导出 .md)、composer(Enter 发送,Shift 换行) |
| `stores/index.ts` | `Stores/*.swift` | AppStore/ProjectsStore/PapersStore/ReaderStore/ChatStore/SettingsStore 逐字段对应(含请求版本号防乱序、附加上下文去重) |
| `api/client.ts` | `Networking/ApiClient.swift` | 端点一一对应;错误 `{detail}/{message}` 解析;列表 10s 超时与超时文案 |
| `api/types.ts` | `Models/Models.swift` | 逐字段 Codable;`PaperStatus` 枚举(§6) |
| `index.css` | `App/Theme.swift` | 全部 CSS 变量→调色板 token(light/dark)、accent-soft/faint 运行时混色、圆角/阴影/字级 |
| `hooks/useMediaQuery.ts` | `horizontalSizeClass` | — |

## 3. 不复刻/死代码

- `reader/LeftPanel.tsx`:Web 工程内**未被任何页面引用**(死代码),逻辑链实际由 `ReadingArea` 内嵌 margin outline 呈现——App 同样不建独立左栏。

## 4. localStorage → UserDefaults 同名迁移

`paperico:last-paper`、`paperico:left-width`、`paperico:right-width`、
`paperico:reader-mode:<id>`、`paperico:text-progress:<id>`、`paperico:pdf-progress:<id>`、`paperico:pdf-zoom:<id>`。

## 5. 已声明的原生等价替换(非偏离功能,偏离实现)

1. **KaTeX** → LaTeX `$$…$$/$…$` 以等宽展示块/行内呈现(系统无原生 LaTeX 渲染;不引第三方)。
2. **pdf.js 文本层选择** → PDFKit 原生选择 + 工具条"引用选中内容"按钮(等价交互);译文区按块附加上下文(上下文菜单"加入论文对话")替代任意划选浮钮。
3. **pdf.js 像素滚动进度** → PDFKit 页码进度(原生习惯),仍按 paper 记忆/恢复。
4. **`<select>`/`input[type=color]`** → 原生 `Picker`/`ColorPicker`(保留 hex 文本输入)。
5. **HTML 表格 `dangerouslySetInnerHTML`** → 轻量解析 `<table>` 后用原生网格渲染,失败回退图片/标题。
6. **react-router** → 页面枚举 + 自绘导航(SwiftUI NavigationStack 不适合胶囊导航形态)。

## 6. 《agentero-lessons-for-paperico》在本工程的应用

| 条目 | 落点 |
|---|---|
| §2.3 状态/错误契约 | `PaperStatus` 枚举(uploaded/parsing/normalizing/analyzing/reducing/parsed/ready/error + 未知兜底)单点定义;`ApiError{status,message}` 结构化,前端不再文本嗅探。后端不改,App 端先收敛 |
| §5 契约防漂移 | `scripts/check_api_contract.py`:拉取后端 `/openapi.json`,对照 `Models.swift` 字段快照(`ios/contract-snapshot.json`),schema 变更即报警;`docs/` 留字段映射 |
| §3.6-8 列表瘦身 | App 仅消费列表页所需字段,重字段(tldr/narrative…)仅在详情/信息卡使用(不改后端,消费侧自律) |
| §6 明确不照搬 | 不引入 MCP/同步/双链/自建版面;App 只做"薄壳 + 就地状态" |
| §2.4 定宽时间戳 | App 解析端兼容 ISO8601 微秒/毫秒两种定宽,便于后端未来迁移 |
| 总原则 | 先保"管线可靠性在客户端的可视化"(状态轮询、错误回显、重试),再谈花活 |

## 7. 构建与运行(在 Mac 上)

1. `open ios/Paperico.xcodeproj`(需 Xcode 16+;签名选 Automatically / Sign to Run Locally)。
2. 选 iOS Simulator(iPhone 16 / iPad Pro)或 My Mac 直接 Run。
3. 首启在 设置 → 服务器地址 填后端(如 `http://192.168.x.x:8000`;App 已允许本地明文 HTTP ATS)。
4. 契约检查:`python3 ios/scripts/check_api_contract.py --base http://127.0.0.1:8000`(或 `--file openapi.json`)。

## 8. 工程生成

`ios/scripts/make_pbxproj.py` 扫描 `ios/Paperico/` 生成 **objectVersion 77(文件系统同步组)** 工程,
增删源文件后重跑即可;`Assets.xcassets` 含单尺寸 AppIcon 与 AccentColor。
