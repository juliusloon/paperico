# Paperico 改进执行计划(基于《Agentero 工程分析》指导)

> 依据:`docs/agentero-lessons-for-paperico.md`(下称"指导文件")。
> 所有"现状"均已于 2026-09-29 在当前代码上**逐条核实**(非照抄指导文件,行号以当前代码为准)。
> 使用方式:按 Phase 顺序执行;每个任务(T 编号)独立提交,勾选验收项后合入。
> 全局约定:SQLite 改表前先 `cp paperico.db paperico.db.bak-<date>`;后端改动必须带 pytest;涉及 API schema 的任务必须同 commit 更新 `ios/scripts/check_api_contract.py` 的 SNAPSHOT 并跑通。

---

## 0. 基线核对表(指导文件条目 → 已核实现状 → 计划归属)

| 指导条目 | 已核实现状(2026-09-29) | 归属 |
|---|---|---|
| §2.1 任务系统缺位 | `BackgroundTasks.add_task` 共 4 处:papers.py:80/247/263/287(全管线、reparse、续跑 reduce、重译);无并发上限、无取消、无启动 reconcile | T1.1 / T1.2 |
| §2.2 `_get_llm` 三处复制 | papers.py:685、chat.py:78 用、notes.py:126;`services/llm.py:199` 已有共享 `get_llm_client`,只差 profile 解析收敛 | T0.3 |
| §2.3 状态/错误裸字符串 | `error_message = str(e)[:500]` 在 papers.py:517/654/680;无 error_code;状态串散落 | T0.1 |
| §2.4 时间戳非定宽 | models.py `_now()` = `datetime.now(utc).isoformat()`(微秒为 0 时变短) | T0.2 |
| §2.5 删除无回收站/不联动取消 | papers.py:292 起:`unlink + rmtree + 删行`,不通知任务系统 | T1.3 |
| §2.6 无入库去重 | 无 sha256;Paper 无对应列 | T1.4 |
| §3.1 Chat 上下文硬截断 | chat.py:`logic_chain[:3000]`、`method_index[:2000]` | T2.2 |
| §3.2 引用可寻址闭环 | `Block.bbox`(JSON 列,models.py:92)**已入库但两个前端都没用**;cited chip + 译文视图闪高亮已有 | T2.3 |
| §3.3 Map/Reduce raw 丢失 | 无任何 raw 落盘;清洗规则改动即需重跑 LLM | T2.1 |
| §3.4 列表接口偏重 | PaperListItem 含 narrative_summary/contributions/difficulty_estimate/venue,列表卡片不用 | T3.5 |
| §3.5 跨论文对比无供给方案 | MethodsPage 仅展示,无对比编排 | T3.4 |
| §4.1 元数据识别≈0 | title 从第一个 section_heading 猜(papers.py:556);authors/year/venue/DOI 恒空 | T3.1 |
| §4.2 本地解析无超时 | mineru.py:229 `AsyncClient(timeout=None)`;cloud 已有 max_wait=600s | T3.2 |
| §4.3 进度粒度 | 前端只见 analyzing 一个状态,无批次进度 | T3.3 |
| §5 契约防漂移 | 后端无 OpenAPI 快照;前端 types.ts 手写;原生 App 已有 `check_api_contract.py`(13 schema 校验通过) | T4.1 |
| §5 真实论文回归 | 仅 test_pipeline.py / test_storage.py 单测 | T4.2 |
| §5 迁移写法 | 无 Alembic,手动 ALTER;现仅 1 次批量改表需求 | T4.3 |

依赖关系:`T0.1/T0.2/T0.3` 相互独立,可并行;`T1.1` 是 `T1.2/T1.3/T3.3` 的前置;`T1.4`、`T2.*`、`T3.1/T3.2/T3.5` 独立;`T4.1` 建议在 Phase 1 结束(schema 变更沉淀后)落地并此后随改随更。

---

## Phase 0 — 契约与一致性(P0,合计 ≈1 天)

### T0.1 PaperStatus 枚举 + 结构化错误码 `- [x]`(2026-09-29 实现;枚举额外补充 `MINERU_PARSE_FAILED`,本地/云端解析失败与通用提交失败区分)

- **目标**:状态与错误从裸字符串变为单一枚举定义 + `{code, message}` 结构化错误,前端可编程决策。
- **现状**:`error_message = str(e)[:500]`(papers.py:517/654/680);状态串散落在 papers.py / stores / 测试。
- **改动**:
  1. 新建 `backend/app/core/status.py`:`class PaperStatus(StrEnum)`(uploaded/parsing/parsed/normalizing/analyzing/reducing/ready/error)+ `class ErrorCode(StrEnum)`:`MINERU_NOT_CONFIGURED / MINERU_TIMEOUT / MINERU_SUBMIT_FAILED / LLM_NOT_CONFIGURED / LLM_TRUNCATED / LLM_CALL_FAILED / JSON_PARSE_FAILED / PDF_MISSING / PARSE_EMPTY / INTERRUPTED_BY_RESTART / INTERNAL`。
  2. `Paper` 增列 `error_code VARCHAR NULL`;所有写 `error_message` 处同时写 `error_code`(截断 500 保留给人类阅读)。
  3. `PaperListItem` / `PaperStatusOut` 增加 `error_code: str = ""`;手动迁移:`ALTER TABLE papers ADD COLUMN error_code VARCHAR`。
  4. 各 except 分支把异常映射到 ErrorCode(MinerU 提交失败/轮询超时/LLM 4xx/JSON 解析失败…),未知 → INTERNAL。
- **验收**:任一失败路径入库后 `error_code ∈ ErrorCode`;`/api/papers?status=` 仍用字符串(与枚举值一致);pytest 断言映射表全覆盖。
- **联动**:前端 `types.ts` 加 `error_code?`;出错舞台优先展示 code 对应文案;原生 App `Models.swift` 的 `PaperListItem/PaperStatusOut` 加 `errorCode`(同 commit 更新契约 SNAPSHOT,`check_api_contract.py` 会红→绿)。
- **量级**:0.5 天。

### T0.2 定宽时间戳(RFC3339 毫秒)+ 一次性迁移 `- [x]`(2026-09-29 已对活库执行,备份 `paperico.db.bak-20260929-205132`;66 行时间戳重写,复跑幂等)

- **目标**:`_now()` 输出定宽,字符串排序永不再漂移。
- **改动**:
  1. models.py `_now()` → `datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'`(24 字符定宽)。
  2. 一次性迁移脚本 `backend/scripts/migrate_timestamps.py`:遍历 `papers(created_at,last_opened_at)`、`chat_messages(created_at)`、`notes(created_at,updated_at)`,把旧格式(`…+00:00` / 缺毫秒)统一解析后重写为定宽;幂等(已是定宽则跳过)。
  3. 在 `test_pipeline.py` 加断言:新建行时间戳长度 == 24 且以 `Z` 结尾。
- **验收**:迁移后 `SELECT created_at FROM papers` 全部 24 字符;按 created_at 排序与按 datetime 排序一致(测试内对比)。
- **量级**:0.25 天(含脚本)。

### T0.3 LLM profile 解析收敛到 `services/profiles.py::resolve_llm` `- [x]`(2026-09-29 实现三处调用点收敛;以 papers 版语义为基准,chat/notes 一并补齐"已配置优先"回退)

- **目标**:回退语义单一实现,三处复制清零。
- **现状**:papers.py:685(map/reduce 回退链)、chat.py:78、notes.py:126 各自 `_get_llm`;前端 SettingsPage 写死 5 个 role 全部指向同一 profile。
- **改动**:
  1. 新建 `backend/app/services/profiles.py`:`class LlmRole(StrEnum)`(TRANSLATION_AND_EXTRACTION / LOGIC_CHAIN_AND_SUMMARY / FIGURE_VISION / CHAT / NOTE_SYNTHESIS);`resolve_llm(app_settings, role) -> LLMClient`(内部复用 `llm.get_llm_client`)。回退链按指导文件:logic_chain → translation → chat;note_synthesis → chat;chat → chat;figure_vision → chat;translation → chat;空串/缺失即下落。
  2. 三个 api 文件删本地 `_get_llm`,改调 `resolve_llm`;行为保持不变(以现有测试 + 手测一条 chat 保证)。
- **验收**:grep 全仓 `_get_llm` 仅剩 0 处;pytest 全绿;新增 `test_profiles.py` 覆盖 5 个 role × (命中/回退/全空→报 LLM_NOT_CONFIGURED)。
- **量级**:0.25 天。

---

## Phase 1 — 任务治理(P0,合计 2–3 天)

### T1.1 最小 JobCenter:并发上限 + 注册表 + 取消 `- [x]`(2026-09-29 实现 `core/jobs.py`;4 处 add_task 收敛为 `jobs.submit(mineru/map/reduce)`,reparse/resummarize/retranslate 先取消旧任务;回退开关 `use_job_center` 保留)

- **目标**:连续上传不再打满 MinerU/LLM 配额;reparse/重译先取消旧任务,杜绝双写。
- **现状**:4 处裸 `background_tasks.add_task`;reparse 清 Block 后旧任务可能仍在写。
- **改动**:
  1. 新建 `backend/app/core/jobs.py`:
     - `class JobCenter`:按 kind 的 `asyncio.Semaphore`(`mineru=2, map=2, reduce=2, translate=2, figure=2`,配置可覆盖);`_registry: dict[str, set[asyncio.Task]]`(键 paper_id);`submit(kind, paper_id, coro)` 包一层:信号量内执行、完成/异常时从 registry 移除、`CancelledError` 静默上抛(不写状态)。
     - `cancel_for_paper(paper_id)`:对 registry 内任务 `task.cancel()` 并 `await asyncio.gather(..., return_exceptions=True)`。
     - `has_active(paper_id) -> bool`(供 reconcile 与测试)。
  2. FastAPI lifespan 挂 `app.state.jobs`;papers.py 4 处 add_task → `jobs.submit(...)`;`reparse` / `retranslate` 入口先 `await jobs.cancel_for_paper(paper_id)`。
  3. `_process_paper` 内部写库保持"每批次一个事务"现状(取消点安全),并在各阶段开始处 `await asyncio.sleep(0)` 提供取消检查点。
- **验收**:pytest:并发提交 6 篇 mock 论文,同一时刻 mineru 类并发 ≤2;reparse 期间旧任务被取消(用计数器断言旧协程不再写 Block);进程内重复提交同 paper 的任务互斥语义由调用方保证(记录到 docstring)。
- **量级**:1 天。

### T1.2 启动 reconcile(重启自愈) `- [x]`(2026-09-29 实现 `services/reconcile.py`,挂 lifespan;content_list 需 JSON 可解析才续跑,续跑前清残留 Block;kill -9 模拟实测:无缓存→INTERRUPTED_BY_RESTART,有缓存→从 map 续跑)

- **目标**:进程重启后不再有永久 `parsing/analyzing` 僵尸。
- **改动**:lifespan 启动时:对 `status ∈ {parsing, normalizing, analyzing, reducing}` 且 `not jobs.has_active(paper_id)` 的论文:
  1. `mineru_output` 目录存在且 content_list 可读 → 置 `parsed` 并 `jobs.submit("map", ...)` 从 Map 续跑(复用现有 reparse 的缓存续跑路径);
  2. 否则置 `error`,`error_code=INTERRUPTED_BY_RESTART`,`error_message="服务重启导致解析中断,请重新解析"`。
- **验收**:pytest:构造两种状态的假论文 + 假/真输出目录,断言两条路径;手动 kill -9 后重启实测一次。
- **量级**:0.5 天(依赖 T1.1、T0.1)。

### T1.3 删除联动取消 + 回收站 `- [x]`(2026-09-29 实现 `core/trash.py` + `scripts/restore_from_trash.py`;删除=取消任务→文件移入 `.trash/<batch>/<paper>/`→写 manifest→删行,移动失败自动回滚;启动清理超 7 天 batch;恢复脚本含 `--list`)

- **目标**:防误删;删除时任务先取消。
- **改动**:
  1. `delete_paper`(papers.py:292)流程改为:`await jobs.cancel_for_paper(id)` → 文件(pdf、mineru_output、figures)移入 `storage_root/.trash/<batch_id>/<paper_id>/` → 写 `manifest.json`(paper 元数据 + 原相对路径 + deleted_at)→ 删 DB 行。
  2. 启动时清理 `.trash` 中 `deleted_at` 超过 7 天的 batch(配置项 `trash_retention_days`)。
  3. 恢复 v1 走脚本:`backend/scripts/restore_from_trash.py <batch_id>`(移回文件 + 按 manifest 重建 Paper/Block 行);不做 UI。
- **验收**:pytest:删除运行中论文,registry 清空且后台协程不再写库;删除后 `.trash` 结构与 manifest 字段完整;restore 脚本对 fixture 跑通。
- **量级**:0.5–1 天(依赖 T1.1)。

### T1.4 文件 sha256 入库去重 `- [x]`(2026-09-29 实现;上传流式分块计算 sha256,命中 409 并清理临时文件;`file_sha256` 列已随 migrate_schema_v2 上活库,备份 `paperico.db.bak-20260929-212042`)

- **目标**:同一 PDF 重复上传直接拒绝,不再白烧 MinerU + Map。
- **改动**:
  1. `Paper` 增列 `file_sha256 VARCHAR NULL`(手动 `ALTER TABLE ... ADD COLUMN`);上传流(papers.py create)计算 sha256(流式分块读)。
  2. commit 前查重:命中 → `HTTP 409`,`detail = "与已有论文《title》重复(id)"`;URL 来源(source_url)暂只记录 hash 备用。
  3. 存量论文不回填(可选脚本 `backfill_sha256.py` 放 Phase 4,低优先)。
- **验收**:pytest:同一文件二次上传返回 409 且指向已有 id;不同文件正常。
- **联动**:前端 `handleUpload` 已 catch 并展示 message,无需改;原生 App `uploadFiles` 同样直接展示 `ApiError.message`。
- **量级**:0.5 天。

---

## Phase 2 — 上下文工程(P1,合计 2–3 天)

### T2.1 Map/Reduce 原始输出落 raw sidecar(单条收益最高) `- [x]`(2026-09-29 实现 `storage.write_analysis_raw` + map/reduce 全部 4 条管线路径捕获 raw;全管线/重译均写 map_raw.json+reduce_raw.json,写失败仅告警;pytest 覆盖批次捕获/修复重试捕获/文件结构/写失败不阻塞)

- **目标**:清洗/派生规则迭代零 LLM 成本重放。
- **现状**:`analysis.run_map_phase`(:43)/`run_reduce_phase`(:352)清洗后丢弃原始 JSON。
- **改动**:
  1. `storage.py` 增 `analyses_dir(paper_id) -> Path`(`storage_root/analyses/<paper_id>/`)。
  2. map/reduce 结束时各写 `map_raw.json` / `reduce_raw.json`:`{model, created_at, batches: [{block_ids, raw_response}], reduce: {...}}`;figure 分析可选同格式。
  3. 写失败不阻塞管线(try/except + log)。
- **验收**:跑一次管线后两个文件存在且可 `json.load`;pytest 用假 LLM 断言文件结构。
- **量级**:0.5 天。

### T2.2 Chat 上下文分层瘦化(按优先级丢弃,不再机械切字符) `- [x]`(2026-09-29 实现 `services/context.py`;200 块长文预算内整行丢弃、section heading 恒保留;pytest 抓到并修复 flush_group nonlocal 崩溃 bug;`chat_legacy_truncation` 开关保留一轮)

- **目标**:长论文后段不再从 system prompt 里无声消失;截断点永远落在语义边界。
- **现状**:chat.py `logic_chain[:3000]`、`method_index[:2000]`。
- **改动**:
  1. 新建 `app/services/context.py::build_paper_context(blocks, entities) -> str`:
     - 逻辑链:按 `role_in_narrative` 分节,相邻同角色合并为一行 `ROLE · [b00xx] one_liner(≤120 字)`;section_heading 行永远保留;总预算 6000 字符,超预算按"非 heading 尾部优先丢弃"。
     - 方法索引:仅 `name(category)→[b00xx…]`;实体按 `block_refs` 数取 Top-K(K=40)。
     - attached_context:text_selection snippet ≤240 字(现有),figure 摘要 ≤400 字。
  2. chat.py 系统提示组装改调该函数;删除两处硬截断。
- **验收**:pytest:构造 200 块长文,断言 ①输出 ≤ 预算 ②所有 section heading 在场 ③无行被切成两半;真实论文手测一轮 chat 质量不回退。
- **量级**:0.5–1 天。

### T2.3 引用闭环最后一块:PDF 画布 bbox 定位(Web + 原生 App) `- [x]`(2026-09-29 实现:坐标勘验 `docs/bbox-coordinate-system.md`(0–1000 双轴归一化);BlockOut 增 bbox 并同步 4 处契约(openapi 快照/ios SNAPSHOT/types.ts/Models.swift);Web `pendingPdfFocus`+百分比高亮层,原生 `PDFAnnotation` 1.8s 闪高亮;chip/逻辑链节点/实体标签三入口全接,PDFKit y 轴翻转;live API 实测 96/96 块带 bbox)

- **目标**:点 cited chip / 逻辑链节点 → 原文 PDF 翻到对应页并按 bbox 闪烁高亮。
- **现状**:`Block.page_idx/bbox` 已入库(models.py:91–92),两个前端都未消费;PDF 视图仅 zoom/进度。
- **改动**:
  1. **先做一次坐标勘验**(0.5h):取一篇真实论文的 `bbox` 样本,确认 MinerU 输出坐标系(0–1000 归一化 or 像素),在 `docs/` 记录换算公式。
  2. Web `ReadingArea/PdfReadingArea`:reader store 增 `pendingPdfFocus: {blockId} | null`;cited chip / OutlineNode 点击在 `viewMode==='pdf'` 时写 focus;PdfReadingArea 消费:翻到 `page_idx` 页 → 在页面上叠一层绝对定位高亮 div(bbox 换算)闪烁 1.8s 后移除。
  3. 原生 App `PdfReadingArea`:`ReaderStore.pendingPdfFocus` 同名机制;PDFKit 侧 `go(to: page)` + 临时 `PDFAnnotation`(border 透明、fill accent 30%),1.8s 后移除。
- **验收**:三种入口(chip、逻辑链节点、实体标签)在 PDF 模式下均能跳页+高亮;译文模式行为不回归。
- **量级**:1 天(web)+ 0.5 天(native)。

---

## Phase 3 — 元数据与编排(P1,各 ≈1 天,可并行)

### T3.1 DOI/arXiv 元数据识别链(本地优先、静默降级) `- [ ]`

- **改动**:
  1. `Paper` 增列 `doi VARCHAR NULL`、`arxiv_id VARCHAR NULL`、`meta_source VARCHAR DEFAULT 'local'`(一次 ALTER 三列)。
  2. 新建 `app/services/metadata.py`:
     - 从 MinerU content_list 前 2 页文本正则提 `10.\d{4,9}/…` 与 `arXiv:\d{4}\.\d{4,5}(vN)?`;
     - 命中 DOI → Crossref `GET /works/{doi}`(timeout 8s,无 Key);命中 arXiv → Atom API;取 title/authors/year/venue(container-title);
     - `meta_source` 语义:`recognized`(自动识别写入)/ `manual`(用户改过,此后永不自动覆盖)/ `local`(现状);识别失败静默返回,绝不阻塞管线。
  3. 挂在 Map 之前的管线空闲点(解析完成后);`reparse` 时 `meta_source != 'manual'` 才允许覆盖。
  4. **去重键扩展**(衔接 T1.4):同 doi/arxiv_id 再入库同样 409。
- **验收**:pytest(mock Crossref/Atom):识别、失败降级、manual 不覆盖三条路径;真实论文手测 1 篇。
- **量级**:1 天。

### T3.2 本地 MinerU 解析 deadline `- [ ]`

- **改动**:mineru.py:229 本地 Gradio 路径加与 cloud 一致的 600s 总预算(轮询循环累计计时,超时抛 `MinerUTimeout` → `error_code=MINERU_TIMEOUT`);顺带把该文件所有外部调用的总时长预算过一遍。
- **验收**:pytest:mock 挂起的本地端点,断言 600s(测试里调小常量)内抛错且论文进入 error。
- **量级**:0.25 天。

### T3.3 进度粒度:批次进度接口 `- [ ]`

- **改动**:
  1. JobCenter(T1.1)增 `progress: dict[paper_id, dict]`;`analysis.run_map_phase` 每完成一批更新 `{stage:"map", done, total}`;reduce 同理。
  2. `GET /papers/{id}/status` 响应增加 `progress: {stage, done, total} | null`。
  3. Web ReadingArea processing-stage 显示"翻译并提炼段落 43/120"(已有 3.5s 轮询,只改渲染);原生 App 处理中舞台同款展示。
- **验收**:pytest 断言 progress 推进与清零(完成/失败后清空);前端手测。
- **量级**:0.5–1 天(依赖 T1.1;schema 变更 → 同步契约 SNAPSHOT)。

### T3.4 跨论文对比两阶段编排(NEED_FULLTEXT) `- [ ]`

- **改动**:
  1. 新端点 `POST /api/library/compare`(SSE,复用 chat 流式设施):system prompt 注入各论文压缩目录(reduce 产物 one_liner + 方法索引,单篇 ≤8KB,总量 ≤40KB);允许模型输出 `NEED_FULLTEXT <paper_id> <b0001-b0099>` 结束本轮。
  2. 服务端检测到标记:返回 `done` 事件附 `needs: [{paper_id, block_range}]`;前端 MethodsPage 新增"跨论文对比"入口(对话式):检测 needs → 拉取对应 Block 原文(截断 ≤12KB)→ 以附加上下文自动发续轮;两轮后仍未决则直接作答(优雅降级)。
  3. 每轮注入的 block 全文带 `[b00xx]` 前缀,保证引用闭环格式一致。
- **验收**:pytest:mock 模型先输出 NEED_FULLTEXT 再作答,断言两轮编排;前端手测一篇双论文对比。
- **量级**:1 天(schema 无表变更;新增请求体 → 契约脚本补 SNAPSHOT)。

### T3.5 列表接口瘦一档 `- [ ]`

- **改动**:`/api/papers` 列表返回 slim 项(去掉 `narrative_summary / contributions / difficulty_estimate / venue`;保留 `tldr`——首页最近阅读在用);`/papers/{id}` 详情维持全量。前端 `PaperListItem` 类型拆出 slim 子集;原生 `Models.swift` 同步(SNAPSHOT 更新)。
- **验收**:契约脚本绿;库页/首页渲染无回归。
- **量级**:0.5 天。

---

## Phase 4 — 质量基建(P2)

### T4.1 OpenAPI 快照测试 + 生成式类型 `- [x]`(2026-09-29 后端快照落地:`tests/test_openapi_snapshot.py` + `tests/openapi_snapshot.json`,`UPDATE_SNAPSHOT=1 pytest` 刷新;生成式前端类型暂不做)

- 后端:`tests/test_openapi_snapshot.py` 断言 `json.dumps(app.openapi(), sort_keys=True, ensure_ascii=False)` 与 `tests/openapi_snapshot.json` 一致;`UPDATE_SNAPSHOT=1 pytest` 刷新;**改任何 schema 忘更新快照即红**。
- 前端(可选):`openapi-typescript` 从快照生成 `src/api/schema.d.ts`,types.ts 逐步对齐(不强制一次替换)。
- 原生:已有 `ios/scripts/check_api_contract.py`;把"后端改 schema 的 PR 必须同时更新该脚本 SNAPSHOT"写进贡献约定。
- **量级**:0.5 天。

### T4.2 真实论文 opt-in 全管线回归 `- [ ]`

- `tests/test_real_pipeline.py`:env `PAPERICO_E2E_PDF_DIR` 未设则 skip;用 1–2 篇真实 PDF + MinerU 缓存 fixture 跑全管线,断言:块覆盖率、译文完整率(text_zh 非空占比 ≥ 阈值)、逻辑链覆盖(role_in_narrative 非空占比 ≥ 阈值)、T2.1 的 raw 文件存在。
- **量级**:0.5 天。

### T4.3 Alembic 引入决策(条件触发,暂缓) `- [ ]`

- 现状仅一次批量改表(T0.1/T0.2/T1.4/T3.1 合并成**一个** `backend/scripts/migrate_schema_v2.py`,单套写法,遵循"从第一天只有一套迁移"教训)。
- 触发条件:该迁移之后再次需要改表 → 引入 Alembic 并把 migrate_schema_v2 作为 baseline 之前的记录;在此之前不引入。
- **量级**:0(决策项)。

---

## 明确不做(护栏,防过度工程,来自指导文件 §6)

- ACP Client / MCP Server / headless CLI(无本地 Agent 场景)
- crate/服务拆分、tauri-specta 类契约框架(保持 services 收敛 + api 薄壳)
- 自建版面分析 / 21 条版面规则 / 本地 ONNX(MinerU 唯一引擎)
- S3/WebDAV 同步、远程 Vault、双链 Wiki 索引
- 回收站 UI(T1.3 v1 只做脚本恢复)

## 与原生 App(ios/)的联动点汇总

| 后端任务 | 原生 App 动作 |
|---|---|
| T0.1 error_code | `Models.swift` 增 `errorCode`;失败舞台按 code 显示文案;更新 `check_api_contract.py` SNAPSHOT |
| T1.4 / T3.1 去重 | 无改动(409 message 已透传展示);可选:重复提示里跳转已有论文 |
| T2.3 bbox 闭环 | `PdfReadingArea` 增 `pendingPdfFocus` + 临时 PDFAnnotation(0.5 天) |
| T3.3 progress | 状态轮询响应增 `progress`,处理中舞台显示 n/m |
| T3.5 slim 列表 | `PaperListItem` 字段对齐(SNAPSHOT 同步) |
| T3.4 compare | 远期:MethodsPage 对话面板的原生实现(先 Web 验证) |

## 执行顺序与里程碑

```
里程碑 A(≈1 天,契约基线):   T0.1 ∥ T0.2 ∥ T0.3  →  合并 migrate_schema_v2.py
里程碑 B(≈2.5 天,管线可靠):  T1.1 → T1.2 → T1.3 → T1.4;随后 T4.1 快照落地
里程碑 C(≈2.5 天,供给质量):  T2.1 → T2.2 → T2.3(web→native)
里程碑 D(≈3 天,能力补齐):    T3.1 ∥ T3.2 ∥ T3.5;T3.3;T3.4;T4.2 收尾
```

## 全局验收清单

- [ ] `pytest backend/tests` 全绿,含新增:profiles / jobs / reconcile / dedup / context 预算 / metadata mock / openapi 快照
- [ ] `ios/scripts/check_api_contract.py --base http://127.0.0.1:8000` 输出 contract OK
- [ ] 真实论文手测脚本(每里程碑跑一遍):上传→解析→阅读→引用跳转(PDF 与译文两种模式)→对话→删除→重启自愈
- [ ] `grep -rn "_get_llm\|\[:500\]\|\[:3000\]\|\[:2000\]" backend/app` 仅剩合理命中(0 处 _get_llm;[:500] 仅存于文案截断处注释说明)
- [ ] kill -9 后重启:无僵尸状态论文(或全部自动续跑/置 error 带 INTERRUPTED_BY_RESTART)

## 风险与回滚

- **改表**:所有新列可空、带默认值,旧代码可读写 → 逐步发布无锁风险;回滚 = `paperico.db.bak-*` 还原。
- **JobCenter 引入**:保留 `add_task` 兜底开关(配置 `use_job_center: bool`,默认 true,异常时可回退旧路径)。
- **Chat 上下文改写**:保留 `chat_legacy_truncation: bool` 配置一轮,观察一周后删除。
- **时间戳迁移**:脚本幂等 + 备份;迁移前后各跑一次列表排序对比。
