# Paperico MCP

Paperico 内置一个 localhost Streamable HTTP MCP 服务。默认关闭；在 **设置 → MCP 连接**
中开启后，外部助手可以只读访问活动论文库。App 必须保持运行。

## 启用与连接

1. 构建或启动新版 Paperico，进入设置的「MCP 连接」。
2. 打开「允许 MCP 客户端只读访问」。首次开启会在 Keychain 创建独立的随机访问 Token。
3. 复制服务地址与访问 Token，填入支持 Streamable HTTP 的 MCP 客户端；也可复制通用
   JSON 配置。Token 不等于 LLM / MinerU 凭据。
4. 保持 Paperico 运行。关闭开关立即断开所有连接；更换 Token 后需要更新客户端配置。

首次启动由系统选择随机可用端口并记住它，之后尽量复用；端口被占用或尚在 TCP 释放等待期
时会换到另一个随机端口，请从设置重新复制配置。地址形式为 `http://127.0.0.1:<port>/mcp`。

客户端需为请求设置 `Authorization: Bearer <token>`。设置页提供的是通用 JSON 配置，不含
软件专属按钮，以下是各客户端的手动配置示例：

```sh
claude mcp add --transport http paperico 'http://127.0.0.1:<port>/mcp' \
  --header 'Authorization: Bearer <token>'
```

这是 [Claude Code 官方文档](https://code.claude.com/docs/en/mcp) 支持的 HTTP + header
配置方式。命令默认使用当前项目的 local scope，需要跨项目时可自行添加 `--scope user`。

Cursor 使用 `~/.cursor/mcp.json`：

```json
{
  "mcpServers": {
    "paperico": {
      "url": "http://127.0.0.1:<port>/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

格式依据：[Cursor MCP 文档](https://prod.cursor.com/help/customization/mcp)。

VS Code 使用用户配置或 `.vscode/mcp.json`，顶层字段与 Cursor 不同：

```json
{
  "servers": {
    "paperico": {
      "type": "http",
      "url": "http://127.0.0.1:<port>/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

格式依据：[VS Code MCP 配置参考](https://code.visualstudio.com/docs/agents/reference/mcp-configuration)。
含 Token 的配置请留在个人设置中，不要提交到仓库。

当前版本只提供 HTTP，没有 bundle 内 stdio 代理。Claude Desktop 的云端 custom connector
不能访问本机 `127.0.0.1`；完整本地 stdio 接入属于 P2。

## 工具与资源

| 工具 | 读取内容 | 必填参数 |
|---|---|---|
| `list_papers` | 论文元数据列表，可按项目、状态、标题/文件名过滤 | 无 |
| `search_library` | 按英文标题、中文标题与文件名匹配，不搜索正文与译文 | `query` |
| `get_paper` | 元数据、摘要、贡献、难度、方法实体、逻辑大纲 | `paper_id` |
| `get_blocks` | 原文/译文正文块及引用关系 | `paper_id` |
| `get_block` | 单块内容与证据 | `paper_id`, `block_id` |
| `get_figure` | 单块信息 + MCP image content | `paper_id`, `block_id` |
| `list_projects` | 分组与论文数 | 无 |
| `get_method_index` | 跨论文方法及证据块 ID | 无 |
| `search_methods` | 方法名称搜索，可按分组/分类过滤 | `query` |
| `get_notes` | 已保存笔记 | `paper_id` |

列表工具使用 `offset`（默认 0）和 `limit`（默认 50，最大 200）。结果对象包含 `items`、
`total`，存在下一页时还有 `next_offset`。搜索/筛选参数为 `query`、`project_id`、
`status`（论文）或 `category`（方法）。工具返回 JSON text 和相同的 structuredContent；
图像同时返回 image content，保留 block ID 与图注供引用。

每篇活动论文提供四个 `application/json` 资源：

- `paperico://paper/{paper_id}/metadata`
- `paperico://paper/{paper_id}/blocks`
- `paperico://paper/{paper_id}/chat`
- `paperico://paper/{paper_id}/notes`

支持 `resources/list`、`resources/templates/list` 和 `resources/read`。资源列表按 50 篇
论文分页，使用 MCP `nextCursor`；整份资源过大时请改用分页工具。

## 架构与协议

服务内嵌在 App 进程中，所有读取复用 App 的同一个 `PaperLibrary` actor，不创建第二个库
实例。现有 JSON 读改写没有 suspension，提供单进程一致性；actor 本身并不保证跨 `await`
的事务，也没有跨进程锁。当前实现只读，所有详情调用使用 `markOpened: false`，读取不写
索引。

SDK 与监听器隔离在 `macos/MCP` 包内，核心 target 不依赖 SDK；`PaperPipeline` 与
`KeychainStore` 属于 App，不在 SwiftPM 的 `PapericoCore` 目标中。服务基于官方
[Swift SDK 0.12.1](https://github.com/modelcontextprotocol/swift-sdk/blob/0.12.1/Package.swift)
（其 manifest 要求 Swift 6.1），按
[2025-11-25 稳定协议](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
实现；该版本不接受 JSON-RPC batch。
[新版草案](https://modelcontextprotocol.io/specification/draft)已改用逐请求协商，后续
升级需要做兼容测试。

服务是无状态的：仅支持 `/mcp` 的 POST，GET 与 DELETE 返回 405（无 SSE 的 Streamable
HTTP 允许此行为）。每个请求创建独立的 SDK Server 与 transport，避免不同客户端复用请求
ID 时相互覆盖，也不产生 MCP session ID。

## 安全边界

- 仅绑定 IPv4 **127.0.0.1**，不监听 LAN、Bonjour 或公网。
- 每次请求必须携带 `Authorization: Bearer <token>`。Token 由系统随机源生成 256 bit，
  存于 Keychain，显示与复制均由用户操作。LLM / MinerU 凭据没有任何 MCP 读取接口。
- 验证 Host 与存在时的 Origin，拒绝任意域名、`null` Origin、重复 header 和有歧义的
  body framing。没有 CORS 开放或通用文件服务。
- 最多 16 个并发连接。header 上限 16 KiB、请求 body 上限 1 MiB、总连接超时 30 秒、
  SDK 请求超时 20 秒。列表有分页；JSON 结果上限 6 MiB，图像原文件上限 4 MiB，编码后
  的完整 HTTP 响应上限 12 MiB。
- 图像必须属于该论文的 `mineru_output` 目录，解析符号链接后验证路径；只返回
  PNG / JPEG / GIF / WebP。回收站论文及其保留文件不向外部客户端开放。
- 外部客户端可以读取整个活动论文库，并可能把内容发送给其连接的模型服务；授权范围通过
  设置开关明确告知。MCP 读取不会触发 Paperico 自己的解析、分析、问答或笔记生成。
- App bundle 包含 `com.apple.security.network.server` entitlement。本地 ad-hoc 构建
  已验证签名包含该权限；Developer ID、公证及 App Store 审核属于实际分发流程。

## 验证与后续

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macos
./script/build_and_run.sh --build-only
```

MCP 集成测试使用临时论文库和真实 loopback HTTP，覆盖初始化、10 个工具、资源、图像、
读取不写索引、相同 ID 的并发请求、token / Origin / Host 验证、越界与回收站访问，以及
停服断连、官方 Swift SDK 客户端互通与 Token 撤销。测试不读取用户论文库，也不调用付费
API。

P1 计划实现：导入与处理任务、付费动作的 App 确认、状态/进度与取消、`ask_paper`、笔记
生成与 deep link。其中本地文件导入需要处理 App Sandbox 的文件授权——外部客户端传入
路径不会自动赋予 App 读取权限；付费操作需要服务端权限检查加 App 内确认，客户端
elicitation 不能单独作为可信的授权边界。

P2 计划：stdio 代理、prompts、资源订阅，以及独立评估后的 App Intents——WWDC26 的
[视频](https://developer.apple.com/videos/play/wwdc2026/345/)并未说明 App Intents 能
自动转换成通用 MCP server，不能当作已验证能力。未来的独立只读进程也不能直接复用
`PaperLibrary.load()`，因为它会执行中断状态对账并可能写索引。长任务与服务端主动通知
需要有状态/SSE transport 或新版协议的适配，不能在当前只读 stateless 服务上加入
elicitation 就假定双向交互成立。
