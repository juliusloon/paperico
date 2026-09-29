# MinerU.Chem integration spike

日期：2026-08-28

## 结论

MinerU.Chem 的网页端确实有 Chemistry Paper 模式，当前前端使用的请求字段是顶层
`is_chem: true`，不是 `enable_chem=true`。但是这个字段尚未出现在公开 MinerU v4
API 参数表中；用 Paperico 当前配置的 API token 实测时，`file-urls/batch` 接受了请求，
却只创建普通解析 batch，没有返回 Chem `task_ids`，Chem 配额也没有消耗。因此当前不能把
“HTTP 200”当成 Chem API 已接通。

当前可落地路径是：先支持导入网页端下载的完整 Chem 结果包；同时保留受保护的 API
探针，等官方为 API token 开通 Chem task 后再切到自动解析。不要把普通 MinerU 输出
静默当成 Chem 输出。

参考：

- [MinerU.Chem 论文](https://arxiv.org/abs/2608.03525)
- [MinerU.Chem 产品页](https://mineru.net/chem/)
- [MinerU 在线 Extractor](https://mineru.net/OpenSourceTools/Extractor)
- [公开 MinerU API 文档](https://mineru.net/doc/docs/index_en/)

## 实测对象与结果

Paperico 现有论文：

- Paper ID：`90dca89dd8df`
- 标题：Direct Aldehyde C-H Arylation and Alkylation via the Combination of
  Nickel, HAT, and Photoredox Catalysis
- 普通 batch ID：`79cf6e46-ee4a-4195-931c-230853337d4c`
- 请求：`is_chem=true`、`model_version=pipeline`
- 返回：普通 MinerU ZIP；无 `task_ids`；Chem status 查询为 chemistry task not found
- Chem quota：请求前后均为 `used_quota=0`、`left_quota=50`

这次返回包 SHA-256 为
`63b65838fc23cfe62893b1be23a971a310b5223d4160c15fc321d2d6721eac02`，只包含普通
MinerU 解析文件，不能作为 MinerU.Chem 成功样本。

为了确认真实 bundle，另外下载了 MinerU 官方公开 Chemistry demo：

- Demo ID：`demo-6d1a-411e-8092-3f41910f4829`
- 状态接口：`GET /api/v4/demo-chem/{demo_id}/`
- ZIP SHA-256：
  `caa7527a567aabcbe32c3cedcef43b5b09b19eb7b611a04a8e199ef31379fb9f`
- 实际记录：30 个 molecule、1 个 reaction

冻结结果位于 `backend/app/storage/mineru_chem_spike/`。该目录属于运行时 storage，默认
不会进入版本控制；manifest 保存了来源、请求参数、文件哈希和审计结果。

## 真实文件名

Chem 结果没有分别命名为 `Molecule Summary List` 和 `Reaction Summary List` 的文件。
两张表实际合并在：

- `demonstration_tables.json`：主要契约，顶层为 `pipeline_info`、
  `molecule_table`、`reaction_table`、`summary`
- `apicall_mol.json`：面向分子调用的精简记录
- `molfiles/*.mol`：单分子 MolFile
- `molfiles/mllm_molfile_mapping.json`：识别原始响应与 MolFile 映射
- `moldet_yolo/molecule_crops/figure/*.jpg`：分子局部裁图

`mllm_molfile_mapping.json` 中的 `mol_file_path` 是 MinerU 内部 NAS 绝对路径，不能作为
Paperico 可访问路径保存。应使用 bundle 内相对路径或由 Paperico 重新生成 storage URL。

## JSON schema

### `molecule_table`

容器字段：`table_type`、`description`、`columns`、`data`、`total_molecules`。

本次实际 columns：

```text
mol_id, mol_img, mol_graph, mol_smiles, mol_smiles_unexpanded,
mol_smiles_expanded, mol_identifier, mol_molfile, source_figure, bbox,
confidence, page_idx, block_index, scale_factor, page_bbox
```

其中 `mol_identifier` 是论文标识符（如 `3n`），`mol_id` 是 MinerU 内部 ID（如
`mol_0001`）。`bbox` 与 `page_bbox` 都需要原样保留，坐标含义必须结合 `scale_factor`
和原始页面尺寸验证，不能未经校准直接画到 Paperico PDF canvas。

`apicall_mol.json` 的记录字段为：

```text
mol_id, page_idx, bbox_normalized, smiles_expanded, smiles_unexpanded,
mol_idt, mol_block
```

### `reaction_table`

容器字段与 molecule table 类似。本次实际 columns：

```text
reaction_id, reaction_figure, reaction_conditions, reaction_smiles,
reactants, products, reactants_smiles, products_smiles, source_figure,
confidence, page_idx, block_index, scale_factor
```

关系不能只从 `reactants` / `products` 读取：

- `reactants`、`products` 主要保存 bbox、page_bbox、category；
- 可关联分子的 `mol_id`、SMILES、MolFile、crop path 位于
  `reactants_smiles` / `products_smiles` 的角色包装对象中；
- `reaction_conditions` 是带 `type`、`condition`、bbox、page_bbox、
  scale_factor 的数组；
- demo 中 `reaction_smiles` 为空，即使各参与者 SMILES 已存在，所以导入器必须允许空值，
  不能假设总能直接复制 reaction SMILES。

## Bundle 完整性边界

官方 demo JSON 共引用 61 个相对资源，其中 30 个 molecule crop 存在；30 个
`molgraph/*.png` 和 1 个 `reaction_extraction/visualize/*.jpg` 不在下载 ZIP 中。通过
status 返回的 `base_url` 直接访问这些缺失路径也得到 403。因此第一个版本应：

- 把 crop、MolFile 和原始 JSON 作为可用证据；
- 对缺失的 `mol_graph` / `reaction_figure` 明确标记 unavailable；
- 需要重绘时从已审核的 MolFile/SMILES 本地生成，不伪装成 MinerU 原始图；
- 导入前执行 schema 与 referenced-artifact audit。

## Paperico spike 代码

- `backend/app/services/mineru_chem.py`：发现、严格校验并审计真实 Chem bundle；保留原始
  provider payload，不覆盖识别结果。
- `backend/app/services/mineru.py`：显式转发 `is_chem`；要求独立 Chem task ID；轮询
  `/extract/task/{task_id}/chem-status`；保存完整 `chem-result.zip`。缺少 Chem task 时快速
  失败，禁止静默降级。
- `backend/scripts/mineru_chem_spike.py`：可复现下载、检查和 token 探针。
- `backend/tests/test_pipeline.py`：覆盖 schema、缺失 artifact 和静默降级保护。

复现官方 demo：

```bash
cd /path/to/paperico
PYTHONPATH=backend backend/.venv/bin/python \
  backend/scripts/mineru_chem_spike.py download-demo \
  --output /tmp/paperico-mineru-chem-demo
```

检查已有解压包：

```bash
PYTHONPATH=backend backend/.venv/bin/python \
  backend/scripts/mineru_chem_spike.py inspect \
  backend/app/storage/mineru_chem_spike/demo-6d1a-411e-8092-3f41910f4829/extracted
```

用一个 API token 探测隐藏参数（成功时会真正提交任务）：

```bash
MINERU_API_KEY='replace-me' PYTHONPATH=backend backend/.venv/bin/python \
  backend/scripts/mineru_chem_spike.py probe-api /path/to/paper.pdf
```

## 复验（2026-08-28 晚）

账号状态有变化，但 API 结论不变：

- `GET /api/v4/chem-quota` 现在返回 `has_quota=true, total_quota=50, left_quota=50`
  （此前 `used_quota=0` 且无可用配额）。说明账号已获得网页端 Chem 资格。
- 用同一 token 重新提交 `is_chem=true`（顶层、文件级、`model_version=vlm` 三种变体），
  响应均无 `task_ids`，只创建普通 batch；下载 ZIP 无 Chem 文件；Chem quota 仍为
  `used_quota=0`；`GET /extract/task/{batch_id}/chem-status` 返回
  `-60012 chemistry task not found`。
- `POST /extract/task/batch` 用已上传 OSS URL 创建任务失败
  （`failed to read file`），不是可用的 Chem 入口。
- 公开 API 文档仍无 `is_chem` 或任何 Chem 参数。
- 官方 demo 状态接口与结果包仍可正常访问。

判断：Chem 能力本身可用（网页端 + 本账号配额），但“用 API token 自动触发”仍不可行，
最可能的原因是 Chem task 需要网页登录会话或尚未对 token 开放。维持原建议：
第一版做网页端 ZIP 手工导入，同时向 MinerU 申请 API 侧 Chem 权限后再自动化。

## 下一交付建议

第一版应先做“导入 Chem ZIP”，再新增 Molecule、Reaction、ReactionParticipant 与审核状态，
最后接 Chem 面板、chips、Chat context 和 CSV/SDF 导出。自动 API 路径必须以返回独立
Chem task 且下载包通过 schema 校验为启用门槛。跨论文子结构检索、自动路线重建和
ORD 导出仍放第二阶段；Chat 与论文逻辑链 prompt 优化作为独立改动，在结构化 Chem
context contract 稳定后进行。
