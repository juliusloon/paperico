# Paperico 原生 App(iOS + macOS)

将 paperico Web UI/功能 1:1 复刻的原生 SwiftUI 多平台应用,只使用原生组件
(SwiftUI / PDFKit / URLSession / UserDefaults),**零第三方依赖**,直接对接现有
FastAPI 后端(`backend/`,不改动)。

- 架构与逐组件映射:[`docs/ios-app-plan.md`](../docs/ios-app-plan.md)
- 源码:`Paperico/`(Swift),工程:`Paperico.xcodeproj`
- 后端契约防漂移:`scripts/check_api_contract.py`

## 环境要求

- macOS + **Xcode 16 及以上**(工程使用 objectVersion 77 文件系统同步组格式)
- 目标:iOS 17.0+ / macOS 14.0+(同一 target,见 `SUPPORTED_PLATFORMS`)

## 构建与运行

```bash
open Paperico.xcodeproj
```

1. Scheme 选 `Paperico`;目标选 **iPhone 16 模拟器 / iPad Pro / My Mac**。
2. 签名:自动签名即可(模拟器免签;真机/Mac 选 "Sign to Run Locally" + 团队)。
3. Run(⌘R)。

命令行构建:

```bash
xcodebuild -project Paperico.xcodeproj -scheme Paperico \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

xcodebuild -project Paperico.xcodeproj -scheme Paperico \
  -destination 'platform=macOS' build
```

## 连接后端

App 是原生客户端,后端跑在任意一台机器上(`./start.sh`,默认 `:8000`):

1. 首启进入 **设置 → 服务器地址**,填入后端地址,例如
   `http://127.0.0.1:8000`(Mac 本机)或 `http://192.168.x.x:8000`(iPhone → 局域网 Mac)。
2. 点 ✓ 保存并检测,出现"后端连接正常"即可。
3. 之后 AI 模型 / MinerU 配置与 Web 端共用同一份数据库配置(读写 `/api/settings`)。

明文 HTTP:IP 直连与 localhost 本就豁免 ATS;工程已额外声明
`NSAllowsLocalNetworking` 以支持局域网主机名。macOS 端已启用 App Sandbox
并授予网络客户端 + 用户选定文件读写(上传 PDF / 导出笔记)。

## 本地开发循环

- 增删 Swift 文件:工程使用文件系统同步组,**无需**重新生成工程;
  如需重写 `project.pbxproj`,运行 `python3 scripts/make_pbxproj.py`。
- 后端 schema 变更后跑契约检查:

  ```bash
  # 后端运行中:
  python3 scripts/check_api_contract.py --base http://127.0.0.1:8000
  # 或离线:
  python3 -c "import json,sys;sys.path.insert(0,'../backend');from app.main import app;print(json.dumps(app.openapi()))" > openapi.json
  python3 scripts/check_api_contract.py --file openapi.json
  ```

  输出 `contract OK` 说明 `Paperico/Models/Models.swift` 与后端字段一致;
  否则按提示补齐 Swift 模型并更新脚本内 SNAPSHOT。

- Linux 上可做 Swift 语法级预检(无法做类型检查,需要 macOS 才能编译):

  ```bash
  pip install tree-sitter tree-sitter-swift
  python3 scripts/check_swift_syntax.py
  ```

## 功能对齐(1:1 复刻)

| 页面 | 覆盖 |
|---|---|
| 首页 | hero 文案/装饰画/指标/最近阅读/工作流面板 |
| 论文库 | 项目分组(新建/重命名/删除/拖拽投递*)、搜索、状态/排序筛选、多选批量移动删除、内联重命名、上传弹层(PDF 多选)、4s 状态轮询 |
| 方法索引 | 类别侧栏计数、搜索、方法卡展开论文跳转 |
| 设置 | AI 模型 / MinerU(云/本地)/ 阅读外观三表单,测试连接,就绪度卡,notice;**新增服务器地址** |
| 阅读器 | 边栏逻辑链大纲(随内容滚动)、双语/原文切换、字号缩放、重新翻译(+后台错误回显)、处理中/失败舞台与重新解析、进度条与进度记忆、文本↔PDF 切换 |
| PDF | PDFKit 连续滚动、缩放记忆、按页进度记忆、原生划选 → "引用选中内容"加入对话 |
| 对话 | SSE 流式、会话管理、引用证据 chips(跳块+闪高亮)、附加上下文 chips(选段/方法卡/图表)、预设提示词、笔记模式(多选生成 + 导出 .md) |

\* 拖拽投递目前仅 macOS(真拖拽);iOS 用选择条完成同样操作。

## 与 Web 的已声明差异

全部为"原生等价替换",详见 `docs/ios-app-plan.md` §5:
LaTeX 以等宽样式呈现(无 KaTeX)、译文区按块附加上下文(附上下文菜单)、
PDF 进度按页、原生 ColorPicker/Picker、服务器地址为原生客户端必需新增项。
