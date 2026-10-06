# Paperico 架构文档

适用版本：1.0.1（build 10）· 更新日期：2026-10-06。

本文只描述仓库内跟踪的内容，是面向外部读者的官方架构说明。本地保留、不入库的材料
（历史 backend / frontend、内部规划文档、验证日志等）在 `architecture-FULL.md`（不入库）
中一并描述；逐文件明细见 `macos/architecture.md`。

## 1. 总体形态

Paperico 是一款 macOS 原生学术论文阅读与翻译工具：导入 PDF → MinerU 解析 → LLM 生成
全文译文、段落要点、逻辑链与方法索引 → 离线阅读器精读、证据引用问答与笔记导出。

- **原生 App 是唯一产品路径**。SwiftUI + Swift Concurrency，除 MCP 包内的官方 Swift SDK
  外零第三方依赖；本地 JSON + Keychain 存储，直连 MinerU 与 OpenAI 兼容模型服务，
  不依赖任何自建后端。
- **Python 后端已退出发布物**。v0.1 的 FastAPI/SQLite 兼容服务不再随仓库分发，源码只
  存在于 git 历史；`start.sh` 与 `script/` 仍保留，用于历史 API 的本地参考运行。
- **数据事实边界**：云解析会上传 PDF，模型请求会发送论文文本或上下文。本地存储与
  调用外部 AI 是两个独立事实，本机保存不等于数据不出本机。

## 2. 仓库地图

| 路径 | 内容 |
|---|---|
| `macos/Paperico/` | 原生 App 源码：App / Stores / Core / Models / Pages / Chat / Components / Support / Resources |
| `macos/MCP/` | 独立 SwiftPM 包 `PapericoMCP`：App 内嵌的只读 MCP 服务器 |
| `macos/reader-renderer/` | 阅读器离线渲染器的开发源码与构建脚本（渲染产物随 App 打包） |
| `macos/Tests/` | SwiftPM 核心测试与 MCP 互操作测试 |
| `macos/scripts/` | DMG 打包、API 契约检查、阅读器性能基准等脚本 |
| `macos/architecture.md` | 逐文件架构指南 |
| `script/` | `build_and_run.sh`、`check.sh`、`check_markdown_rendering.sh` |
| `docs/` | 本文档、`mcp.md`、`releases/`（各版本发布说明与验证记录） |
| `README.md` / `README.en.md` | 中文为主、英文对照的项目说明（cn-first 结构） |
| `start.sh` | 历史 REST/SSE 兼容后端的本地启动脚本 |

`backend/`、`frontend/`、`design/`、`CHANGELOG.md`、`.github/` 与内部规划文档为
本地保留、不入库的材料，见 `architecture-FULL.md`。

## 3. 运行与依赖图

```mermaid
flowchart TD
    Entry[PapericoApp: 单一工作台窗口 + 设置/About] --> Model[AppModel]
    Model --> Bootstrap[AppBootstrap: 打开本地库 / 装载设置与凭据]
    Bootstrap -->|成功后呈现页面| UI[SwiftUI Pages]
    Bootstrap -->|失败| Recovery[保留文件 / 错误视图 / 重试]
    UI --> Stores[Settings / Projects / Papers / Reader / Chat / Update / MCP Stores]
    Stores --> Library[PaperLibrary actor]
    Stores --> Pipeline[PaperPipeline]
    Stores --> Chat[ChatService]
    Stores --> Update[UpdateStore → AppRelease → GitHub Releases]
    Pipeline --> Gates[JobGate ×2: MinerU / LLM 各限 2]
    Gates --> MinerU[MinerUClient 云端/本地]
    Gates --> Analysis[AnalysisEngine single_pass / bounded_batches]
    Analysis --> LLM[LLMClient]
    Chat --> LLM
    Pipeline --> Library
    Chat --> Library
    MCPStore[MCPStore] --> Automation[LibraryAutomation] --> Library
    Library --> Files[library.json + papers/&lt;id&gt;/*]
    Stores --> Creds[CredentialStore] --> Keychain[Keychain: credentials.v1]
```

`AppEnvironment` 以可观察对象类型注入同一份服务图；App 单工作台窗口，阅读与对话状态
由共享 Store 持有。若将来支持多论文窗口，必须先把这些状态下放到窗口。

## 4. 数据边界与一致性

### 4.1 本地数据布局

`LibraryLayout` 负责路径，`LibraryIndex` 负责轻量索引，`LibraryFiles` 负责严格读取和
原子写入。数据按论文分文件存放，避免每次修改对话都重写全库：

```
Application Support/Paperico/
  library.json              项目 + 论文索引（schema version 1）
  papers/<id>/blocks.json   解析块            papers/<id>/entities.json  方法实体
  papers/<id>/chat.json     对话会话          papers/<id>/notes.json     笔记
  papers/<id>/reader-annotations.json  阅读器注释草稿
  mineru_output/<id>/       解析结果、图像与分析日志（含 cloud-task.json 提交断点）
```

`library.json` 含 `projects`、`papers`、`shaByPaperId`、`sourceUrlByPaperId`、`trash`、
方法目录（`methodContent` / `methodAliases` / `hiddenMethods` / `methodAddedAt`）与
`methodGroups`。可读取早期无版本索引；更高版本或损坏 JSON 明确报错——不存在文件与
无法读取文件是两种情况，后者不能退化为空数据。

论文文件 SHA-256 是内容去重键，失败论文也参与去重；回收站存在相同 PDF 时提示恢复。

### 4.2 actor 内事务写入

小型本地 JSON 操作在 `PaperLibrary` actor 内完成，读、改、写之间没有 suspension，
配合原子写入防止半份 JSON；索引写失败时回滚内存到最后成功写入的版本并把错误传回
调用方。这提供单进程内的串行一致性，**不是跨进程锁，也不是整篇论文多文件数据库事务**。
分析失败时可能保留已完成的阶段产物；只有最终成功写入后才把论文标为 ready。

### 4.3 删除、恢复与永久删除

删除先等待该论文处理任务结束，再把元数据移入索引 `trash`；PDF、正文、图像、会话和
笔记保留在原路径，迟到的写入会检查论文是否仍存在。恢复重新激活同一 ID：原分组已删除
时回到未分组，原记录处理中时转为可重试错误。永久删除逐篇确认：先取消处理任务，再
依次删除 PDF、正文、图像、会话、笔记与分析产物；任一步失败保留回收站记录可重试，
删除后同一 PDF 可重新导入。没有定时自动清空。

### 4.4 统一凭据

API Key、MinerU Token 与 MCP 访问令牌集中在**单一钥匙串条目**（service
`com.paperico.native`，account `credentials.v1` 的版本化 Envelope），由进程级单例
`CredentialStore` 管理：串行访问 + 进程内共享授权快照，设置、解析管线与 MCP 复用
同一次读取结果；取消一次授权不会连环弹窗，已有密钥显示"待解锁"而不是阻塞启动。
检测到旧版分散条目时静默迁移，钥匙串锁定导致失败时保留旧条目、不覆盖损坏或更新版本
的统一记录；统一记录一旦存在就不再回退到可能过期的旧值。普通配置存 UserDefaults。

## 5. 处理管线与任务生命周期

### 5.1 状态机

| 状态 | 意义 | 用户操作 |
|---|---|---|
| uploaded | PDF 已本地入库；配置缺失时停在此处 | 在处理任务中开始解析 |
| parsing | 提交、等待 MinerU、下载结果 | 停止；任务终止后重试 |
| parsed / normalizing | 原始结构已返回；转换为 Block | 等待或停止 |
| analyzing | 流式生成完整译文、段落要点、逻辑链与方法索引；长文分段 | 等待或停止 |
| reducing | 兼容旧版本的残留状态；新管线不再进入 | 重启后重试 |
| ready | 所需结果写入成功 | 精读、提问、生成笔记 |
| error | 配置、服务、存储、中断或主动停止 | 重新解析 / 重新翻译 / 恢复已返回结果 |

并发约束分两层：`JobGate`（解析与生成各限 2，可取消 FIFO，取消不遗失许可）限制不同
论文的服务并发；任务 generation 限制同一篇论文的生命周期，重试先取消旧任务并等待其
退出。云端排队中的任务不占用上传许可。重启后残留的处理中状态标为
`INTERRUPTED_BY_RESTART`，要求用户显式重试；App 不会在启动时自动发起可能收费的请求。

`PaperPipeline` 提供 full / reparse / retranslate / recover 四种模式：recover 仅在本地
重建已保存的模型输出，不重新上传、不调用模型。

### 5.2 分析生成：单次与分段

- **single_pass**（短论文）：MinerU 返回后用一次流式请求生成译文、逐段要点、逻辑角色、
  全文叙事和方法索引。
- **bounded_batches**（正文超过 64 个模型节点或 32 KB 原文）：按 16 个节点、12 KB 原文
  划分翻译请求，再用一次全文原文请求生成全局叙事与方法索引；单个超长节点独立处理，
  不拆改解析编号。

正确性约束（全部在本地校验，违反即拒绝标为 ready）：

- `nodes` 输入与输出都以原始块 ID 为对象键，避免非连续 ID 被模型自行递增错移；
  每项须原样回传原文开头片段并逐项核对，防止漏掉穿插图注后整篇错移。
- 按源块顺序还原，拒绝缺失、重复和冲突的编号；兼容旧数组及显式键包装的数组响应。
- 长段落仅返回标题、短标签或译文明显短于原文时拒绝完成；中文要素做本地校验。
- 每个请求只生成一次，失败不自动重试；重试由用户手动发起。
- 分段原始响应与全文汇总响应保存在日志（`mode: single_pass / bounded_batches`，后者含
  `batch_responses` 与 `metadata_response`）；已完整校验的节点合并为恢复文档，
  **手动「继续处理」**按相同原文指纹（`input_fingerprint`）与分段范围（`batch_count`）
  复用已完成批次，原文变化则明确拒绝。已完整返回的键值节点可在本地修复未转义引号等
  JSON 瑕疵，但缺失字段和编号不会补造。

### 5.3 输出预算与模型行为

生成前通过 `GET /models` 探测显式输出容量，按文本量估算预算，不把上下文窗口误作输出
上限。默认预算 65,536 tokens，能力探测缺失时设置界面允许最高 131,072；分段与汇总请求
通常各 16,384。Kimi 与 Qwen3.5 全文翻译关闭思考输出（Qwen3.5 用其专用
`chat_template_kwargs.enable_thinking=false`，DashScope 用平铺 `enable_thinking=false`），
其他可调模型使用低思考预算；对话和笔记保持用户设置。全文分析以提示词约束 JSON，
不启用服务端强制 JSON grammar；连续 2,048 个空白或同一方法条目重复 4 次即停止生成
并保留响应。超限、缺失节点、HTTP 错误或损坏响应显示具体错误并保留 `single_pass.json`
作为恢复入口。

### 5.4 云端解析

轮询响应按已知任务状态校验，任务面板透出排队、页码进度与 trace ID；
`mineru_output/<id>/cloud-task.json` 保存提交断点，配置匹配时「继续处理」复用已提交
任务而不重新上传；「重新解析 PDF」总是提交全新任务。ZIP 解包在分配输出前检查目录
边界、条目长度、加密/zip64/符号链接与解压大小，条目长度与 CRC32 必须匹配。

### 5.5 正文范围

`PaperContentScope` 在解析后判定正文范围：摘要前的出版信息、作者、DOI，以及参考文献、
致谢与可用性声明仅保留原文，不翻译、不进入逻辑链；References 之后的 Methods、
Materials and Methods、Appendix 与扩展图表重新计入正文。缺少摘要标题的版式保守识别
开篇摘要，无可靠边界时保留正文。排除块不进入模型请求，以空分析记录保留原始编号与
顺序；旧论文在显示和目录中即时使用同一筛选，不重写原始文件。

## 6. 阅读器、对话与笔记

- **离线正文渲染**：正文与同行逻辑链在 `PaperDocumentView` 的单个离线 WKWebView 中
  渲染，Charter / Iowan 与中文宋体排版、上下标与 KaTeX 数学。渲染器读取原生 DTO，
  字体与 Markdown/KaTeX 随 App 打包；桥接消息含论文 ID，核对当前论文与 block/entity ID
  后才能附加上下文或跳转；CSP 禁止外部连接，HTML 仅接受 sup/sub 与表格白名单，
  合法 HTTP(S)/mailto 链接才交给系统打开。
- **布局**：`ReadingArea` 保持同一响应式正文，窄宽自动隐藏页边链并由浮动目录导航；
  右侧信息与对话面板宽度足够时并列、不足时滑出画布。玻璃背景与组件透明度在
  `LocalPrefs` 持久化。PDF 进度按视口顶部所在页与页内位置连续计算并恢复。
- **大纲**：`PaperOutline` 为逻辑链与浮动目录提供同一层级，保留 MinerU 标题级别，
  旧数据可从编号或 Markdown 标题推断；不改写原始解析数据，不重新调用模型。
- **对话**：`ChatStore` 绑定论文 ID，切换时重置状态并作废旧请求；`ChatService` 是唯一
  持久化方，结束后读取实际会话，保证界面消息与磁盘 ID 一致。模型先输出
  `<paperico-title>…</paperico-title>`（≤20 字中文）作为会话标题再回答。证据引用以
  原文块 ID 校验后渲染为 `CitationInlineText` 的原生玻璃按钮（TextKit 附件，随段落
  换行），点击跳转并高亮证据块。`ChatRevision` 支持编辑提问重发与重新生成，生成独立
  修订会话、保留原会话；会话支持重命名与确认删除（保留已导出笔记）。
- **注释编辑**：`ReaderAnnotationEditor` 用原生玻璃面板编辑节点标题与 Markdown 笔记，
  写入 `reader-annotations.json`；Return 完成、Shift+Return 换行，Cmd+B / I / H
  加粗、斜体、高亮，退出阅读器时统一保存/放弃确认。
- **图像与安全**：本地图像用 ImageIO 后台下采样（≤1600px，缓存 96 MB / 80 张），错误
  状态明确显示，原始文件不被覆盖。笔记导出经 `MarkdownExporter` 以 UTF-8 原子写入
  用户选定位置，取消不报错。

## 7. 论文库与工作区

- 单一工作台窗口；导航、目录扩展为同一块 320pt 玻璃面板，窄窗侧栏覆盖并压暗周围。
- 论文与方法都支持分组拖拽（`WorkspaceDragSource` / `WorkspaceDropTarget`，锚定指针的
  拖拽预览与目标组加号提示）；方法组持久化于 `methodGroups`，八个预设分组空时也显示，
  支持建组、重命名、删除与跨组移动，重名检查；新论文分析会带入现有方法组与方法身份，
  保留手工编辑过的索引项。
- 卡片与分组操作收入上下文菜单，内联编辑用 `InlineNameEditor`；对话历史重命名固定在
  标题行尾。搜索同时匹配原文标题、译文标题与文件名；方法类别筛选只作用于已返回的
  索引项，不令其他类别消失。
- 处理任务与回收站是工作台内的独立玻璃窗口，可同时打开，Escape 只关闭当前窗口。

## 8. MCP 只读服务与更新检查

- **MCP**（默认关闭，设置页显式开启）：独立 `PapericoMCP` 包隔离官方 Swift SDK 与
  `NWListener`，Streamable HTTP 监听 `127.0.0.1:<port>/mcp`，Bearer Token 为
  `mcp.access-token`。提供 10 个只读工具（papers / blocks / figures（≤4 MiB 图像内容）/
  projects / method index / notes 等）与 `paperico://paper/{id}/{kind}` 资源；读取复用
  `PaperLibrary`，不改变 last-opened、不暴露凭据、不触发付费调用。详见
  [mcp.md](mcp.md)。
- **更新检查**：`UpdateStore` + `AppRelease` 通过 GitHub Releases API（带页面回退）做
  语义化版本比较；默认每日最多自动检查一次，可在设置或 About 页手动检查、按 tag
  忽略提示。

## 9. 测试与交付

- SwiftPM 目标：`PapericoCore`（排除 GUI 层与管线主类的可测核心）+ `PapericoMCP`；
  测试目标 `PapericoCoreTests` 与 `PapericoMCPTests`，共 23 个文件、约 138 个测试函数，
  覆盖索引一致性、并发导入/保存、管线恢复（分段断点、指纹校验）、MinerU 轮询、
  凭据迁移、正文范围、方法索引、对话引用与会话管理、MCP 真实 HTTP 互操作等。
  核心测试不调用外部 AI。
- `script/check.sh` 一键运行 Python 工具测试、`swift test` 与（存在时的）历史后端
  检查；`script/build_and_run.sh` 构建运行；`macos/scripts/make_dmg.sh` 打包。
- CI 与 Release runner 使用 macos-26，与当前 Liquid Glass / Icon Composer 工程要求一致。
- v1.0.1 实机验证基线见 [releases/v1.0.1.md](releases/v1.0.1.md)：长文分段翻译、
  断点恢复、证据问答与笔记导出全程可复核。

## 10. 已知边界

- 旧后端 SQLite / Fernet 数据与原生 JSON / Keychain 之间**没有自动迁移桥接**，升级
  说明要求保留旧数据。
- 单进程串行一致性不替代跨进程锁；每请求单次生成、失败不自动重试是刻意选择。
- 阅读与对话状态共享，App 为单一工作台窗口。
- 图表依据 MinerU 图注与表格文本分析，不包含另一次视觉模型推理。
- `macos/architecture.md` 逐文件指南仍标注 v0.2.5 / v0.3.0，内容滞后于 1.0.x，待更新。
