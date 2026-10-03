<div align="center">

# Paperico

**本地优先、自带 Key（BYOK）的原生论文精读工作台。**

导入 PDF，用 MinerU 恢复结构，以 AI 辅助双语阅读、梳理论证、证据问答和笔记沉淀。

[![CI](https://github.com/juliusloon/paperico/actions/workflows/ci.yml/badge.svg)](https://github.com/juliusloon/paperico/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/app-v0.2.4-orange)](CHANGELOG.md)

[English](README.md) · 简体中文

</div>

## v0.2.4

正文在所有窗口宽度下使用同一布局，增加悬浮目录、恢复逻辑链连线，并将无标题玻璃卡片
改为从右侧划入。重做提问框、缩短历史标题，统一圆形图标控件与两页搜索。设置支持实时
调整背景透明度；首页增加功能介绍和使用指引。离线数学排版与一次全文分析流程继续沿用。

macOS App 已独立运行：论文库、解析与分析任务、对话和笔记均由原生代码管理，无需启动
Python 后端。新增任务管理和可恢复回收站，并修复启动崩溃、并发存储与取消任务交错问题。

阅读[更新说明](docs/releases/v0.2.4.md)或[仓库分析与架构说明](docs/architecture.md)。

## 功能

- **论文库**：项目分组、搜索、排序、多选移动、PDF 去重、批量导入逐文件错误报告。
- **任务管理**：查看待处理和失败论文、停止处理、重新解析、复用段落重新翻译。
- **双语精读**：原文与译文、逻辑链大纲、方法卡片、原始 PDF、证据跳转与阅读进度记忆。
- **证据问答**：可附带选段、方法或图表；模型回答中的有效 block 引用可定位原文。
- **笔记**：选择对话生成 Markdown 笔记，支持导出。
- **回收站**：删除后保留 PDF、解析结果、对话和笔记，可直接恢复。
- **原生桌面交互**：Liquid Glass、深浅色外观、自定义强调色、⌘1–⌘3 页面导航和 ⌘, 跳转设置页。

## 使用与运行

当前 App target 要求 **macOS 26+、Xcode 26+**。已验证环境为 macOS 27 / Xcode 27、Apple Silicon。

```bash
git clone https://github.com/juliusloon/paperico.git
cd paperico
./script/build_and_run.sh
```

脚本会构建并启动 App；若系统选中 Command Line Tools 而标准路径已安装 Xcode，脚本会
为本次构建自动选择 Xcode。也可以打开 `macos/Paperico.xcodeproj`，选择 Paperico → My Mac → Run。
Codex 的 Run 按钮使用同一脚本。

1. 在论文库导入 PDF。尚未配置服务时，论文保留在本地，状态为待解析。
2. 在设置中保存 AI 模型的 Base URL、模型名与 API Key，测试连通性。
3. 配置 MinerU 云端 Token，或选择自己部署的本地 Gradio 服务。
4. 配置完成后，从论文库的 **处理任务** 开始解析。后续导入会在配置就绪时自动处理。
5. 阅读过程中点击回答的证据引用，可跳转到对应段落或 PDF 位置。

**本地优先不等于离线 AI**：使用云端 MinerU 会上传 PDF；模型端点会接收任务所需的论文
文本和对话上下文。App 直连你配置的服务，Paperico 不提供中转服务器。

## 架构与目录

```text
SwiftUI 页面 → Observable Stores → PaperLibrary / PaperPipeline / ChatService
                                       │                  │
                                 本地 JSON 与文件      MinerU / LLM
```

| 目录 | 职责 |
|---|---|
| `macos/Paperico/App/` | 启动、依赖注入、路由、主题和原生场景 |
| `macos/Paperico/Stores/` | 按设置、项目、论文、阅读和对话拆分的可观察状态 |
| `macos/Paperico/Core/` | 本地持久化、任务闸门、处理管线、服务客户端与 ZIP 读取 |
| `macos/Paperico/Pages/`、`Components/` | 页面、阅读器与通用控件 |
| `macos/Tests/`、`macos/Package.swift` | 不启动 UI、不调用外部服务的核心回归测试 |
| `script/` | 仓库级构建、启动、验证入口 |
| `backend/` | 保留的 v0.1 REST/SSE 服务与 Python 测试，独立于新版 App |
| `docs/` | 当前架构、版本说明和历史工程记录 |

本地的 `frontend/`、`design/` 为忽略的历史 Web 实现与设计资料，不属于当前 App 构建。

## 数据与升级

App 沙盒中的数据根目录：

```text
~/Library/Containers/com.paperico.native/Data/Library/Application Support/Paperico/
├── library.json          # 版本化项目、论文、去重索引与回收站记录
├── pdfs/                 # 原始 PDF
├── papers/<id>/          # blocks、entities、chat、notes JSON
├── mineru_output/<id>/   # 解析结果与图表
├── analyses/<id>/        # 分析原始响应
└── logs/                 # 可选诊断日志
```

服务配置、外观与进度在 UserDefaults；API Key 与 MinerU Token 在 macOS 钥匙串。
存储错误会明确显示，损坏或未知版本的索引不会被当作空库覆盖。

v0.2.0 可读取原生迁移期间的无版本 JSON 索引。**旧 Python 后端的 SQLite 论文库、Fernet
密钥和原生论文库仍是两份独立数据，目前不会自动转换**；升级前请保留旧数据库和存储目录。
备份原生库时请复制整个数据根目录，包括回收站引用的数据；钥匙串凭据需要单独管理。

## 验证与打包

```bash
./script/check.sh                    # 原生核心测试 + 完整 App 构建
./script/check.sh --with-backend     # 加跑已有后端测试、lint 和 DTO 契约检查
./script/build_and_run.sh --verify   # 构建、启动并确认进程运行
./macos/scripts/make_dmg.sh CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

DMG 输出在 `macos/build/Paperico-0.2.4.dmg`。本地构建使用临时签名，未经 Developer ID
公证。正式分发的签名选项见 [macOS 开发说明](macos/README.md)。

## 可选的旧 API 服务

需要独立 REST/SSE API 的用户仍可运行 `./start.sh`，或参考 [backend/README.md](backend/README.md)。
该命令启动 Python 服务，不是新版 App 的启动入口；`backend/.env` 与 `PAPERICO_*` 环境变量
也不会配置原生 App。

贡献约定见 [CONTRIBUTING.md](CONTRIBUTING.md)，安全说明见 [SECURITY.md](SECURITY.md)。

[MIT](LICENSE) © 2026 juliusloon。
