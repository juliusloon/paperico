# macOS 阅读页性能 & 窗口外观排查记录

结论日期:2026-09-30 · 环境:macOS 27.0(26A428) / Xcode.app / Swift 6.2

---

## 0. 一个前提:本机无法用 xcodebuild 编译 Swift 宏

`swift-plugin-server` 启动时会调用 `sandbox_apply`,在当前执行环境被拒绝,
于是所有 `@State` / `@Observable` 都无法展开:

```
sandbox-exec: sandbox_apply: Operation not permitted
error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
```

因此本轮验证改用两条可执行的路径:

1. `ios/scripts/typecheck_no_macros.sh`
   把 `@State` 换成类型等价的 `CheckState`、`@Observable` 换成 `: Observable`,
   再对**整个模块**跑 `swiftc -typecheck`(结果:0 error)。
2. `ios/scripts/run_reader_bench.sh`
   阅读页的开销主体是纯函数(解析 / 字典 / 字符串),这些文件不含宏,
   可以直接编译成 CLI 基准程序,跑真实 `GET /api/papers/{id}` 数据。

在 Xcode 里正常构建(验证方式见文末):

```bash
cd ios && xcodebuild -project Paperico.xcodeproj -scheme Paperico \
  -destination 'platform=macOS' -configuration Debug build
```

---

## 1. 窗口红绿灯没有融入界面

### 根因

用 AppKit 探针实测(`/tmp/winprobe`,`.hiddenTitleBar` 等效配置):

| 项 | 实测值 |
| --- | --- |
| 红绿灯按钮 | `close={{9,9},{14,14}}` `mini={{32,9}}` `zoom={{55,9}}` |
| `contentView.safeAreaInsets.top` | **32 pt** |
| SwiftUI 首行内容 `minY` | **32 pt** |
| 窗口 `backgroundColor` | `System windowBackgroundColor` |

也就是说:

- `.windowStyle(.hiddenTitleBar)` 生效后,**系统仍会自动保留 32pt 顶部安全区**;
- `GlassKit.trafficLightTopPadding()` 又硬编码了 `padding(.top, 34)` —— 两者叠加成 **66pt** 空档,
  14pt 的按钮孤零零浮在空档上半部,看起来就是一块突兀的"独立标题栏区域";
- 这个值在 7 个页面里各写一遍,**阅读页完全没有**,切页时顶部会整体跳动;
- 窗口 `backgroundColor` 从没被设置过 → resize / 出现动画 / 深浅色切换时露出系统灰色接缝。

### 改动

| 文件 | 内容 |
| --- | --- |
| `App/WindowChrome.swift`(新) | 单一来源:计算 `reservedTopInset = 标题栏高 + 安全区`,返回**补足到 34pt** 的差值;并统一设置 `fullSizeContentView` / `titlebarAppearsTransparent` / `titleVisibility` / 跟随主题的 `backgroundColor` / `isMovableByWindowBackground` |
| `App/RootView.swift` | 注入 `\.trafficLightClearance`;onAppear 与主题变化时调用 `WindowChrome.applyToAll` |
| `Components/GlassKit.swift` | `trafficLightTopPadding()` 改为读环境值,不再是硬编码 34 |
| `Pages/Reader/ReadingArea.swift` | 补上阅读页缺失的留白(且放在 `.background` 之前,避免留白区没有底色) |

macOS 26+ 上 `additionalTopClearance = 34 - 32 = 2pt`,总留白回到 ~34pt;
若将来运行在安全区为 0 的旧系统,则自动退化为完整的 34pt。

---

## 2. 阅读页加载失败 / 极度卡顿

### 根因(按实测贡献排序)

1. **一次性构建全部 block** — `ReadingArea.documentBody` 用 `VStack + ForEach`,
   打开论文瞬间就把 80~180 行(含 Markdown 富文本、实体行、GeometryReader)全部
   构建并布局,而且每一行都永久留在视图树里参与失效。
2. **Markdown 每次渲染都重新解析,没有缓存** — `MarkdownText.body` 直接调
   `parseBlocks(_:)` + 每段 `AttributedString(markdown:)`,SwiftUI 每帧失效都会重跑。
3. **每个 row 各自重建实体字典** — `blockRow` 里
   `Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })`,实测 7.4 ms/次 body 求值。
4. **滚动循环自激** — 每帧 preference 更新 → `updateActiveBlock` → 写 `activeBlockId`
   → 所有 row 失效 → 回到第 1、2 条。
5. **每帧写 UserDefaults** — `updateTextProgress` 每帧 `LocalPrefs.setTextProgress`(磁盘 fsync)。
6. **处理中每 3.5s 整篇重拉** — `ReaderPage.pollLoop` 调 `refreshPaper` 拉完整 detail
   (实测 414 KB / 181 block)并整体替换 `paper`,把所有视图作废重建。
7. **图表/表格图片 100% 取不到** — `ApiClient.filesURL` 把 `image_path` 直接相对 baseURL 解析,
   得到 `http://host/mineru_output/...`(404),而后端挂载点是 `/api/files`。
   `AsyncImage` 每次重渲染都重试,一屏可达 37 张。

### 已排除的假设(有证据)

- **图片/附件以大字段存数据库**:`blocks.image_path` 是 `VARCHAR` 路径,
  整库 `paperico.db` 仅 3 MB,图片在 `app/storage/...`。不成立。
- **文件全部堆积在单一位置**:`app/core/storage.py` 已是按论文的
  `storage_root/analyses/<paper_id>/`、每篇一个 mineru 输出目录。不成立。
- **主线程同步解析 JSON**:`ApiClient` 是 `Sendable` 且非隔离,解码在协作线程池;
  实测 414 KB 解码 6.1 ms,不是瓶颈。
- **PDF 在主线程同步打开**:`PdfCoordinatorBase` 已用 `Task.detached` 加载 `PDFDocument`。不成立。

### 改动

| 文件 | 内容 |
| --- | --- |
| `Support/PaperMarkdown.swift`(新) | 解析抽成纯函数 + `NSCache`(块结构 / AttributedString / 行内公式转换都进缓存) |
| `Components/MarkdownText.swift` | body 改走缓存;`HTMLTableParser` 增加 `rows(for:)` 缓存入口 |
| `Pages/Reader/ReadingArea.swift` | `LazyVStack`;实体字典提升为 `entityMap` 计算属性;进度持久化改为"阈值 + 0.6s 合并";LazyVStack 下恢复进度二次兜底 |
| `Pages/Reader/ReaderPage.swift` | 轮询改为轻量 `/status`,仅状态变化(或每 4 tick)才整篇重载;终态直接退出循环 |
| `Stores/ReaderChatStores.swift` | 新增 `applyStatus(_:)` 只更新状态字段;切换论文时清解析缓存 |
| `Networking/ApiClient.swift` | `filesURL` 修正为 `/api/files/<path>` |
| `Support/AppBootstrap.swift`(新) | 放大共享 URLCache 内存容量(默认太小,AsyncImage 反复回源) |
| `Support/ReaderPerf.swift`(新) | 可选性能追踪:耗时 / 内存 footprint / 帧间隔 / 缓存命中率 |

### 实测(真实数据 + 真实源码,`run_reader_bench.sh`)

| 指标 | 修改前 | 修改后 | 倍数 |
| --- | --- | --- | --- |
| 181 block 论文:全量 body 求值 | 38.7 ms | 1.9 ms | 20× |
| 181 block 论文:滚动单帧 | 35.6 ms(**≈28 FPS**) | 0.19 ms | 191× |
| 165 block 论文:全量 body 求值 | 18.0 ms | 1.1 ms | 17× |
| 165 block 论文:滚动单帧 | 16.4 ms(**≈61 FPS**) | 0.12 ms | 141× |
| 414 KB JSON 解码 | 6.1 ms(非主线程,未优化) | 同 | — |
| 解析缓存常驻内存 | — | 12.8~15.7 MB / 篇(NSCache 受限) | — |

---

## 3. 如何在真机上验证

**A. 加载耗时 / 内存 / 滚动流畅度(内置开关,无需重新编译)**

```bash
defaults write com.paperico.Paperico "paperico:perf-trace" -bool true
log stream --level default --predicate 'subsystem == "com.paperico.app"'
```

每 4 秒输出一次摘要:`reader.open`、`reader.fetchPaper` 耗时、
内存 footprint、`documentBody` 求值次数、缓存命中率、
以及**帧间隔均值/p95/最大**(即滚动流畅度)。
关掉:`defaults write com.paperico.Paperico "paperico:perf-trace" -bool false`。

**B. Instruments(需要 Xcode 打开)**

- Time Profiler → 主线程,看 `PaperMarkdown.parseBlocks` / `AttributedString(markdown:)`
  是否还出现在滚动采样里(修复后应几乎消失);
- Allocations → 打开论文前后的 footprint 增量(预期 ~13 MB 后进入平台期);
- SwiftUI 视图体求值数 → `documentBody` 次数应随滚动平缓增长,而不是每次刷新跳几百。

**C. 直接用基准脚本**

```bash
cd ios && ./scripts/run_reader_bench.sh          # 自动从后端拉第一篇论文
```

**D. 肉眼验收**

- 打开一篇 150+ block 的论文:正文应立刻出现,可立即滚动;
- 滚动时进度条变化平滑,不再周期性卡顿;
- 图表/表格图片能正常显示(修复前全部 404);
- 点击左侧逻辑链节点,正文会真正跳到对应位置(修复前只闪烁不滚动)。
