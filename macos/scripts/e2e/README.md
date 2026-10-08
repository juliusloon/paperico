# 引用质量与库内问答验收

`citations.manifest.json` 已按用户授权自主选题：3 篇公开 arXiv 论文、12 个单篇问题与 4 个
库内/无需跨库问题。章节与短语已对照原文，三篇已通过真实本地 MinerU 的解析、正文覆盖、
章节结构与资源路径检查（2026-10-08，1 项 opt-in 测试，0 失败）。这不代表真实模型问答已通过；
example 仅供说明格式，正式质量报告仍待两套 provider 验收。PDF、解析产物和报告不入库。

固定语料来源（版本与 PDF SHA-256 记录于 manifest）：

- [Transformer](https://arxiv.org/abs/1706.03762v7)，本地文件名 `vaswani2017.pdf`。
- [ResNet](https://arxiv.org/abs/1512.03385v1)，本地文件名 `he2015.pdf`。
- [SimCLR](https://arxiv.org/abs/2002.05709v3)，本地文件名 `chen2020.pdf`。

论文从官方 PDF 链接下载后仅保存在本地。不要把 arXiv 可访问等同于 CC 授权；保留作者与来源，
不将 PDF 再分发至仓库。后续扩充仍保持 3–5 篇、10–15 个单篇问题与 3–5 个库内问题。

每个 `papers` 条目包含原始 PDF 文件名 `file` 与 `questions`。每题包括 `q`、`expect`：
`section` 按章节标题包含匹配，`mustContain` 按证据原文中的任一短语匹配，两者至少一个非空。
无需写死解析 block id。跨论文问题设置 `library: true` 与 `expectPapers` 文件名列表；
`requireTools: true` 与 `requiredTools` 只在 agent 模式要求真实调用，正式题单要求 `get_blocks`；
`requireBlockEvidence: true` 要求每篇预期论文至少有一个块级引用，避免只引用标题即通过。
`maxReadPapers` 可约束无意义的大量读取。example 中的文件名需要替换。

配置既有 `PAPERICO_E2E_PDF_DIR`、`PAPERICO_MINERU_LOCAL_URL`、`PAPERICO_E2E_LLM_BASE_URL`、
`PAPERICO_E2E_LLM_MODEL`、`PAPERICO_E2E_LLM_API_KEY` 后，额外设置：

```bash
PAPERICO_E2E_QUESTIONS=/absolute/path/citations.manifest.json \
PAPERICO_E2E_CHAT_MODE=fallback \
PAPERICO_E2E_OUTPUT_DIR=/absolute/path/local-reports \
macos/scripts/verify_real_pipeline.sh
```

以支持工具调用的真实配置另跑 `PAPERICO_E2E_CHAT_MODE=agent`；该模式先做无副作用能力探测，
未确认支持则失败。显式不支持 tools 的配置跑 fallback；每题只发一次问答生成请求。
两套配置是发布兼容矩阵，不能由同一套 mock 或本地合成数据代替。

未设置 `PAPERICO_E2E_QUESTIONS` 时不执行问答阶段。报告写入验收根目录的
`citations-agent.json` 或 `citations-fallback.json`，包含逐题回答、引用判定、轮次/调用/读取篇数、
fallback 命中与本地排名 p95。排名时延不包含模型网络或工具 IO，工具 IO 单独记录。无排名样本时 p95 为 null，表示未测。首版门禁：引用命中率 ≥0.7，
伪引用=0，答案非空率=1，指定论文全部命中，排名 p95<150ms；门槛只升不降。

真实评测发送语料到所配置的服务并产生相应费用，仅显式执行此脚本时运行，不加入默认检查或 CI。
真实 provider、人工题库、Zotero 实机导出与 macOS 15 视觉验证仍需独立记录。
