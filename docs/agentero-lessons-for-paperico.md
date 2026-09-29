# Agentero 工程分析对 paperico 的优化借鉴指导

> 依据：《Agentero 工程深度分析》（2026-09-29）对照 paperico 当前代码（backend `app/` 4.3k 行 + frontend `src/`）逐条核实后写成。
> 结论只列 **与 paperico 现状实际对应** 的条目，每条标注 paperico 的具体代码位置与 Agentero 的对应经验来源（章节号）。

---

## 0. 结论速览

| 优先级 | 主题 | 一句话 |
|---|---|---|
| **P0** | 任务系统、LLM profile 收敛、状态/错误契约、时间戳、删除安全 | Agentero 踩过的坑，paperico 正在踩，且都在 Damage 扩大前 |
| **P1** | 上下文工程（瘦上下文、可寻址引用、raw sidecar） | Agentero 最值得复用的部分，paperico 数据已备好只差消费 |
| **P1** | 元数据识别链与去重 | paperico 的元数据能力目前几乎为零 |
| **P2** | 防漂移测试、契约生成、真实论文回归 | 质量基建，随功能长大再上 |
| **不搬** | ACP/MCP/CLI、Tauri 拆分、版面合并规则、同步、双链索引 | 形态不同，明确划界避免过度工程 |

---

## 1. 两个项目的前提差异（先划界）

| 维度 | Agentero | paperico |
|---|---|---|
| 形态 | Tauri 桌面 + 本地优先，文件是事实来源 | FastAPI Web + SQLite，DB 是事实来源 |
| 解析供给 | 自建可插拔引擎（liteparse/MinerU/Paddle/VLM）+ 自建版面分析 | MinerU（cloud/local/Chem）单引擎 |
| Agent 接入 | ACP Client + MCP Server + headless CLI 三面开放 | 无（人直接用 Web UI） |
| 规模 | 2685 commits / 52 versions / 多平台 | 单用户自部署，早期阶段 |

**因此：** Agentero 的"协议适配暗知识"（§3.3）、crate 拆分（§2.2）、版面 21 条规则（§3.2）、S3 同步（§5.5）对 paperico 没有直接落点；但它围绕 **上下文供给质量** 和 **管线可靠性** 的工程纪律几乎可以整体移植——这两个命题对 paperico 同样成立（spec §1.2 设计原则 2/3/4 与之一一对应）。

---

## 2. P0 — paperico 正在踩、Agentero 已踩过的坑

### 2.1 任务系统缺位（对应 Agentero §5.2 JobCenter、工程债 V30）

现状：`papers.py:80` 用 FastAPI `BackgroundTasks.add_task(_process_paper)` 跑全管线，带来三个真实问题：

1. **无并发上限**：连续上传 N 篇论文会同时打满 MinerU 提交配额 + LLM 并发；Agentero 按 kind 分配并发上限（本地 cap=1、远端不限、批量入库默认 5）。
2. **无取消**：`reparse`（papers.py:227）清空 Block 后重新入队，但如果旧任务仍在 Map 阶段执行中，旧任务会继续写 Block（两份任务写同一篇论文）。
3. **崩溃丢状态**：进程重启后 `status='parsing'/'analyzing'` 的论文永久卡死，没有任何 reconcile；Agentero 有"孤儿文件夹自愈"（§5.1）+ 启动补扫（auto-ingest reconcile）。

**建议（最小可行 JobCenter）**：
- 进程内 per-kind `asyncio.Semaphore`：`mineru=2, map=2, reduce=2`；入队改为统一调度器而非裸 BackgroundTasks。
- 每个任务带 task-id 注册表，`reparse/retranslate` 先取消该论文的运行中任务（对应 `JobCenter::cancel_for_paper`）。
- 启动时 reconcile：`status ∈ {parsing, normalizing, analyzing, reducing}` 且无活动任务 → 有 MinerU 缓存则标记 parsed 等待续跑，否则置 error 并给出明确 message。

### 2.2 `_get_llm` 已经三处复制、回退语义各自为政（对应 V38"两个家"、V31）

- `papers.py:685`：`translation_and_extraction` / `logic_chain_and_summary`（map 回退 reduce）
- `chat.py:198`：`chat` or `translation_and_extraction`
- `notes.py` 底部：第三份实现，`note_synthesis` or `chat`

目前被前端 `SettingsPage.tsx:54` 同时写入全部 5 个键掩盖。任何一处单独改动（例如新增一个 profile 键、或允许空 assignment）就会产生行为分叉。**趁是 3 处而不是 30 处，收敛到 `services/profiles.py::resolve_llm(app_settings, role)` 单一实现**，role 枚举统一回退链。这是 Agentero"core 收敛业务规则、调用点只做薄壳"的直接应用。

### 2.3 状态与错误是裸字符串（对应 V32 错误分类学空壳、单一模型教训）

- `status` 字符串散落在 papers.py / 前端 store / 测试中：`uploaded/parsing/normalizing/analyzing/reducing/parsed/ready/error/reducing`，无单一枚举定义。
- `error_message = str(e)[:500]`：错误无分类码，前端无法可靠区分"未配置 Key / MinerU 超时 / JSON 解析失败 / PDF 缺失"。

**建议**：定义 `PaperStatus` 枚举（Python `StrEnum` + TS 联合类型）与结构化错误 `{code, message}`（如 `MINERU_NOT_CONFIGURED / LLM_TRUNCATED / PDF_MISSING / PARSE_EMPTY`），`error_message` 保留给人类阅读，`error_code` 供前端决策。Agentero 的教训是"等靠文本嗅探决策的代码出现时就晚了"。

### 2.4 时间戳非定宽（对应 §4.2-27）

`models.py:17` `_now()` 用 `datetime.now(timezone.utc).isoformat()`，微秒为 0 时长度不同；`Paper.created_at.desc()`、`ChatMessage.created_at` 排序都是 SQLite 字符串排序，同秒边界存在排序漂移。**建议统一 `datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'`**（RFC3339 毫秒定宽），一次性迁移存量。Agentero 为此做了整个 schema v7 迁移，paperico 现在数据少，改起来最便宜。

### 2.5 删除无回收站、删除不联动取消（对应 §7.5-29/30）

`delete_paper`（papers.py:291）直接 `unlink + rmtree + 删行`，且不通知任务系统：正在管线中的论文被删除后，后台任务会继续 `db.get(Paper)` → 已删则静默 return（运气好），或对已删 Block 继续 flush（报错回滚成 error 状态，运气差）。**建议**：删除先移入 `storage_root/.trash/<batch>/`（含 manifest），任务注册表先取消该论文任务；恢复 = 移回 + 重新入库。单人场景成本很低，防误删收益高。

### 2.6 无入库去重（对应 §5.1 标识符去重 #406）

同一 PDF 重复上传会完整走一遍 MinerU + Map（真金白银）。**建议**：上传时计算文件 sha256 存入 Paper，commit 前查重命中则拒绝并指向已有论文；后续加 DOI/arXiv id 去重（见 §3.2）。

---

## 3. P1 — 上下文工程（Agentero §7.2，最可直接复用）

### 3.1 Chat 上下文硬截断 → 分层瘦上下文

现状 `chat.py:57-89`：每条消息全量 `select(Block)` + 全量 entities，`logic_chain[:3000]`、`method_index[:2000]` 按字符数硬截断——截断点任意（可能切在某个实体行中间），长论文后面的章节在 system prompt 里完全消失且无提示。

**借鉴 Agentero 的"接口默认瘦 + 渐进披露"**：
- logic_chain 按 `role_in_narrative` 分节压缩（同角色相邻块合并为一行），信息自然收敛，截断从"机械切字符"变成"按优先级丢弃"。
- method_index 只给 `name(category)→blocks`，去掉冗余字段；实体多于 N 个时只保留出现频次 top-K。
- 用户 attached_context 的 ref block 全文注入无长度上限——补 Agentero 式"最小选区上下文"：正文块带前后 ≤240 字符邻近文本，超长截断（Agentero 用 4000 字符上限）。

### 3.2 引用可寻址闭环：数据已备好，只差 PDF 侧消费（对应 §3.2"引用可寻址"）

现状：
- 引用格式 `[b00xx]` + `_extract_block_refs` + cited chip 已有；
- 译文视图 `ReadingArea.scrollToBlock` + 1.8s 高亮闪烁已有（与 Agentero 的黄色闪烁如出一辙）；
- **但 `Block.page_idx / bbox` 入库后前端从未用于 PDF 画布定位**（`PdfReadingArea` 只有 zoom 与阅读进度）。

**建议**：给 PDF 画布补上"点击 cited chip / 逻辑链节点 → 翻到 `page_idx` 页 + 按 bbox 画高亮框闪烁"。这正是 Agentero `papers/….pdf#figure=3` fragment + 高亮闭环的对应物，且 paperico 不需要自建版面分析——MinerU 已经给了 bbox。补齐后"AI 引用可溯源"从译文视图扩展到原文视图，这是 spec §1.2 原则 2 的最后一块。

### 3.3 Map/Reduce 原始输出落 raw sidecar（对应 §3.2-18 raw 与 derived 分离）— **单条收益最高**

现状：Map/Reduce 的 LLM 原始 JSON 在清洗后丢弃，只保留规整后的 Block 字段。以后想改进任何**清洗/派生规则**（实体归并 `_canonical_key`、`_complete_logic_chain` 的 fallback role、关键词截断）都必须重新烧钱重跑整个 Map 阶段。

**建议**：把原始输出落 `storage_root/analyses/<paper_id>/map_raw.json`、`reduce_raw.json`（含模型名与时间）。清洗规则迭代时从 raw 重放，零 LLM 成本。这是 Agentero `layout.json`(raw pre-merge) vs `layout-index.json`(post-merge) 模式的直接移植，对"解析最贵的是 Map"的 paperico 尤其划算。

### 3.4 列表接口再瘦一档（对应 §3.6-8 接口默认瘦）

`PaperListItem` 携带 `narrative_summary / contributions / difficulty_estimate`，库列表页卡片用不到（卡片只显示标题/标签/状态/摘要首行）。列表接口按需省略重字段，详情接口再取——对应 Agentero"abstract 只在 paper_get"。

### 3.5 跨论文对比的两阶段编排（对应 §3.6-9 NEED_FULLTEXT）—— 对应 spec 旅程 D

MethodsPage 跨论文方法对比目前没有上下文供给方案（塞不下多篇全文）。借鉴 Agentero：先注入各篇"逻辑链 + 方法索引"压缩目录（30–40KB 量级），Agent/模型判断需深读某篇时输出 `NEED_FULLTEXT <paper_id> <block range>` 停止，前端补料后发续轮；模型不输出标记就直接作答（优雅降级）。paperico 的 Reduce 产物（one_liner + method_index）天然就是那份"摘要目录"。

---

## 4. P1 — 元数据识别链与解析稳健性

### 4.1 元数据识别几乎为零（对应 §5.1 识别链）

现状：`paper.title` 从第一个 `section_heading` 猜（papers.py:555-558），authors/year/venue/DOI 恒空，title_zh 无来源。

**借鉴 Agentero 的本地优先识别链**（轻量版）：
1. PDF 前 2 页文本正则提 `DOI: 10.xxxx/...` 与 `arXiv:xxxx.xxxxx`（MinerU content_list 里现成有文本）；
2. 命中 DOI → Crossref `/works/{doi}`（免费无 Key）；命中 arXiv → Atom API；两个都失败保留现状（静默降级，绝不阻塞管线——Agentero 的"任何一步失败不影响已完成导入"）；
3. 识别到的 doi/arxiv_id 入库，同时成为 §2.6 的去重键；
4. `meta_source` 字段记录 `recognized / manual / local`，用户手改后识别结果放弃（对应 Agentero `meta_source=manual` 语义）。

### 4.2 解析超时补口

cloud 路径已有 `max_wait=600s`（mineru.py:469，做得对）；**本地 Gradio 路径 `timeout=None`（mineru.py:229）无总时长上限**——本地服务挂起会让该论文永久 parsing。补一个与 cloud 一致的 deadline。同时借鉴"解析必须隔离子进程 + 硬超时 + 可取消"的原则精神：所有外部调用都应有总时长预算。

### 4.3 进度粒度（对应 §5.2 字节进度节流）

Map 阶段可能几分钟，前端只有 `analyzing` 一个状态。SSE/轮询带上"已完成批次数/总批次数"，TopBar 显示"43/120 块"——Agentero 的进度节流思想（变化 ≥1 点才发）同样适用，避免高频轮询。

---

## 5. P2 — 测试与契约防漂移

| Agentero 做法 | paperico 对应物 |
|---|---|
| specta bindings 防漂移测试（改命令必须重新生成，§2.3） | **OpenAPI 快照测试**：`app.openapi()` 序列化存 `tests/openapi_snapshot.json`，schema 变更必须显式更新快照；配 `datamodel-code-generator`/`openapi-typescript` 从 OpenAPI 生成 `api/types.ts`，替代手写 154 行类型（types.ts 与 schemas.py 已存在手工同步负担） |
| 真实论文 opt-in 回归（`AGENTERO_LAYOUT_PDF_DIR` 模式，§3.2） | opt-in 全管线冒烟：1–2 篇真实 PDF + MinerU 输出缓存 fixture，断言块覆盖率、译文完整率、逻辑链覆盖率（现有 test_pipeline.py 之上加一层，env 缺失自动 skip） |
| `cargo test` 分 crate 显式选择 | FastAPI 测试注意 `create_all` 前的迁移语义——新增列时手动补 `ALTER`（当前无 Alembic；表多了之后建议引入 Alembic，对应 Agentero schema 迁移梯子的教训 V33"四套迁移写法"——从第一天就只有一套） |

---

## 6. 明确不照搬清单（防止过度工程）

- **ACP Client / MCP Server / headless CLI**：paperico 无本地 Agent 场景。远期若想让 Claude/其他 Agent 读论文库，MCP Server 是合理方向，现在不做。
- **crate 拆分 / HostHooks / tauri-specta**：形态不同；paperico 的对应物是"services 层收敛业务、api 路由做薄壳"，保持这个分层即可（§2.2 的 `_get_llm` 收敛正是这一原则的补课）。
- **21 条版面合并规则 / 本地 ONNX**：paperico 不自建版面分析，MinerU 已承担，绝不引入第二套。
- **S3/WebDAV 同步、远程 Vault、Connector 兼容**：单机单用户不需要；Obsidian 导出已满足"数据带得走"。
- **双链 Wiki 索引**：笔记仍走 Obsidian 导出；除非未来把笔记库纳入 paperico 管理，否则不建索引。

---

## 7. 建议落地顺序

| 步骤 | 内容 | 量级 |
|---|---|---|
| 1 | 收敛 `_get_llm` 三处复制；`PaperStatus`/错误码枚举；定宽时间戳 | ~1 天 |
| 2 | 最小 JobCenter（信号量 + 取消注册表 + 启动 reconcile）；删除联动取消 + 回收站；文件 sha256 去重 | 2–3 天 |
| 3 | Map/Reduce raw sidecar；Chat 上下文分层瘦化；PDF 画布 bbox 引用闭环 | 2–3 天 |
| 4 | DOI/arXiv 元数据识别链；跨论文 NEED_FULLTEXT 编排；OpenAPI 快照测试 | 各 1 天，可并行 |

> 总原则取自 Agentero 结语并适配 paperico：**先做"上下文供给质量"和"管线可靠性"，再谈 AI 智能上限。** paperico 的 Map-Reduce 供给与分阶段重试已经比多数同类项目扎实；短板集中在任务治理、元数据、以及"结构化数据已备好但前端未消费"的引用闭环。
