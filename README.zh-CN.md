<div align="center">

# Paperico

**本地优先、自带 Key（BYOK）的论文精读工作台。**

上传 PDF，由 MinerU 解析为结构化内容，然后配合 AI 生成的逻辑链大纲、逐句双语翻译、
方法卡片进行精读——对话中的每一条回答都能引用到论文的具体位置。

[![CI](https://github.com/juliusloon/paperico/actions/workflows/ci.yml/badge.svg)](https://github.com/juliusloon/paperico/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/badge/release-v0.1.0-orange)](CHANGELOG.md)

[English](README.md) · 简体中文

</div>

---

## 为什么做 Paperico

精读论文不是"看一遍摘要"。Paperico 围绕 **读 → 理解结构 → 提问 → 沉淀** 这条主线构建，
并坚持一条红线：**AI 的每一次输出都必须可溯源**。一句话摘要、方法卡片、对话引用都要能
指回论文的具体 block；模型对论文未提及的内容必须明确声明，不得杜撰。

一切都在你自己的机器上运行：PDF、SQLite 数据库、抽取的图表、API Key（Fernet 加密存储）
均不离开本机。解析与模型调用由你的后端**直连你自己配置的服务**（MinerU、任意
OpenAI 兼容端点），Paperico 自身不做任何中转代理。

## 功能

- **结构化解析** — PDF 交由 [MinerU](https://github.com/opendatalab/MinerU)（云端
  `mineru.net` 或自托管端点）解析为类型化 block：段落、标题、图、表、公式。
- **逻辑链大纲** — LLM 生成"这一节在论证中扮演什么角色"的逻辑链条目，随滚动位置联动。
- **逐句双语阅读** — 原文/译文对照，支持按 block 重新翻译，目标语言可配置。
- **方法卡片与实体** — 抽取论文中使用的方法，形成跨论文可检索的方法索引。
- **可溯源对话** — SSE 流式对话，每条回答附带证据引用，点击引用跳转并闪烁高亮对应
  block；可附加选中文本、方法卡、图表作为额外上下文。
- **笔记模式** — 多选 block 生成结构化笔记，导出 Markdown。
- **文献库管理** — 项目分组、状态筛选、导入去重、批量操作、回收站与恢复。
- **原生 macOS 客户端** — SwiftUI + PDFKit，零第三方依赖，与任何 API 客户端一样对接
  同一本地后端。
- **PDF 模式** — 结构化视图旁用 PDFKit 显示原始 PDF，阅读进度双向同步。

## 架构

```text
┌──────────────────────┐
│  macOS 客户端(SwiftUI) │    ← 任何 HTTP 客户端都可调用 API
└──────────┬───────────┘
           │  REST + SSE
           ▼
   ┌───────────────────┐   直连调用     ┌───────────────────────┐
   │ FastAPI + SQLite, │ ─────────────▶ │ MinerU（云/自托管）     │
   │ PDF 与 block 本地 │                │                       │
   │ 存储              │ ─────────────▶ │ 任意 OpenAI 兼容端点    │
   └───────────────────┘                └───────────────────────┘
```

| 目录 | 说明 |
|---|---|
| [`backend/`](backend) | FastAPI 后端：任务调度、本地存储、加密配置、REST + SSE API |
| [`macos/`](macos) | macOS 原生客户端：SwiftUI + PDFKit（单 Xcode target） |
| [`docs/`](docs) | 工程笔记：bbox 坐标系、存储迁移、化学结构解析 spike 等 |
| [`design/`](design) | Logo 概念稿与图标资产拆解 |

## 快速开始

环境要求：**Python 3.11+**。

```bash
git clone https://github.com/juliusloon/paperico.git
cd paperico
./start.sh
```

`start.sh` 首次运行会自动创建 Python 虚拟环境并安装依赖，然后启动后端：

- 后端 API：http://127.0.0.1:8000 · 接口文档 http://127.0.0.1:8000/docs

更习惯手动搭建？参见 [`backend/README.md`](backend/README.md)。

### 首次使用

1. 启动 macOS 客户端（见下），进入 **设置** 页填写你的 Key：
   - **AI 模型**：任意 OpenAI 兼容端点（Base URL + Key + 模型名），用于翻译、大纲、
     方法卡片与对话；
   - **MinerU**：`mineru.net` 的 API Key，或把 Base URL 指向你的自托管实例，用于 PDF
     解析。
2. （推荐，替代界面输入）复制 [`backend/.env.example`](backend/.env.example) 为
   `backend/.env` 并填入配置——完整变量见[配置表](#配置)。
3. 在首页上传一篇 PDF，等待解析完成。

> 在设置页填写的 Key 会先经 Fernet 加密再入库；密钥文件保存在后端存储目录下
> （权限 0600），也可以通过 `PAPERICO_ENCRYPTION_KEY` 指定自己的密钥。

### macOS 客户端

原生客户端是单个 SwiftUI target，与后端通过 REST + SSE 通信。

环境要求：macOS 14+、[Xcode 16+](https://developer.apple.com/xcode/)。

```bash
open macos/Paperico.xcodeproj   # 选择 Paperico scheme → Run (⌘R)
```

首启在 **设置 → 服务器地址** 填入后端地址（如本机后端 `http://127.0.0.1:8000`）。
构建细节与 API 契约检查见 [`macos/README.md`](macos/README.md)。

## 配置

后端所有配置均为 `PAPERICO_` 前缀的可选环境变量（从 `backend/.env` 加载），完整列表见
[`backend/.env.example`](backend/.env.example)。常用项：

| 变量 | 用途 | 默认值 |
|---|---|---|
| `PAPERICO_LLM_BASE_URL` | OpenAI 兼容端点（翻译/对话/笔记） | `https://api.openai.com/v1` |
| `PAPERICO_LLM_API_KEY` | LLM API Key（也可在设置页填写） | — |
| `PAPERICO_LLM_MODEL` | 模型名 | `gpt-4o-mini` |
| `PAPERICO_MINERU_BASE_URL` | MinerU API 地址（云/自托管） | `https://mineru.net/api/v4` |
| `PAPERICO_MINERU_API_KEY` | MinerU Key（也可在设置页填写） | — |
| `PAPERICO_ENCRYPTION_KEY` | 加密存储凭据的 Fernet 密钥 | 本地自动生成 |
| `PAPERICO_STORAGE_ROOT` | PDF/图表/解析结果存储位置 | `backend/app/storage` |
| `PAPERICO_JOB_KIND_LIMITS` | 各类任务并发上限，如 `{"mineru": 4}` | — |

设置页配置的 Key 加密入库；环境变量适合无界面部署场景。

## 路线图

- [x] v0.1.0 — 首个开源版本：解析、双语精读、可溯源对话、笔记、文献库、后端与
      macOS 客户端
- [ ] 批量导入（Zotero / arXiv 导出）
- [ ] 项目内多篇论文联合对话
- [ ] 可选的多用户与鉴权模式

各版本变更见 [`CHANGELOG.md`](CHANGELOG.md)。

## 参与贡献

欢迎一切贡献——Bug 报告、文档与代码。开发环境搭建、后端↔客户端 API 契约约定、测试
运行方式请先阅读 [`CONTRIBUTING.md`](CONTRIBUTING.md)。

## 安全

发现安全问题请走私密渠道上报，见 [`SECURITY.md`](SECURITY.md)；请勿公开提 Issue。

## 许可证

[MIT](LICENSE) © 2026 juliusloon。MinerU 通过其公开 API 调用，版权归其作者所有。
