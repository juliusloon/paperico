# PDF 迁移修复与界面更新

> 2026-09-28 更新：按用户要求，UI 已回退至优化前的版本。优化版源码、构建产物与截图见
> [界面存档](ui-archives/2026-09-28-before-rollback/README.md)。PDF 迁移修复与请求防错配逻辑保留。
> 本文下方的 UI 与验证描述是 2026-09-12 的历史记录；本次回退验证见 `verification/ui-rollback-2026-09-28/`。

2026-09-12，本地验收。

## 根因与处理

18 篇论文的 `pdf_path` 和 `mineru_output_dir` 仍指向旧机器的
`/Users/juliusloon/Documents/Files/temp/paperico/`。本地 PDF 实际位于
`backend/app/storage/pdfs/`，因此原始 PDF 接口返回 404。

论文 `72802d5d0d31` 使用早期上传流程留下的 `None.pdf`。已检查该 PDF 首页：
标题为 *Data-Driven, Mechanistically Guided Prediction of Yield and Chemoselectivity
in SuFEx Reactions*，与论文记录一致；保留这一明确的关联，不按上传文件名猜测。

- 数据库已备份至 `backend/paperico.before-storage-migration.db`。
- 启动时将存在的文件引用转换为相对 `storage_root` 的路径，迁移可重复运行。
- 路径处理兼容旧 macOS、Windows 路径；原文读取、重新解析、解析缓存和文件删除均使用统一解析函数。
- 新上传文件保存相对路径。默认数据库与 `.env` 位置相对后端目录确定，不随启动工作目录变化。
- 不存在的源文件不会匹配到其他论文或共享的 `None.pdf`。缺少源文件时，重新解析请求保留现有解析内容。
- 前端阻止旧论文请求迟到后覆盖当前论文，防止快速切换导致错配。

以后迁移时，请一起复制 `backend/paperico.db` 和完整的 `backend/app/storage/`
（包括隐藏的密钥文件）。自定义存储目录可设置 `PAPERICO_STORAGE_ROOT`；
相对值以 `backend/` 为基准。若显式配置了绝对路径形式的环境变量，仍需同步更新。

## 界面变化

- 固定主导航，工作台、论文库、方法索引与设置更容易找到。
- 论文库分开呈现页标题、上传入口、搜索筛选与卡片，保留分组、拖动、重命名和批量操作。
- 卡片增加摘要、项目归属和“原始 PDF / 精读”直接入口；标题可通过键盘访问。
- 首页展示真实最近阅读记录，统一留白、文字层级、卡片边界和深色配色。
- 阅读器在收起目录后仍保留 PDF 切换、缩放等工具，支持新标签页打开原始文件与失败重试。
- 手机使用单栏内容和分组抽屉；检查了 390、768、1024、1440 像素宽度。

## 验证

本次结果：18/18 份 PDF 的接口内容与磁盘文件 SHA-256 一致，HTTP Range
分段读取通过，251 张解析图片均存在。浏览器实际渲染全部 18 份 PDF，未发生未捕获错误。

后端 18 项测试通过，覆盖旧路径、二次迁移、迁移幂等性、论文文件隔离、HTTP
Range、缺失文件与缓存复用等场景。前端构建通过，lint 无错误；现存 7 条
React Hook / Fast Refresh 提示及构建包体积提示见验证日志。

不运行付费 MinerU / LLM 请求。重新解析的文件寻址与缓存复用通过本地测试验证。

```bash
# 项目根目录运行；另一个终端先运行 ./start.sh
PYTHONPATH=backend backend/.venv/bin/python -m unittest discover -s backend/tests -v
backend/.venv/bin/python backend/scripts/audit_storage.py

cd frontend
npm ci
npx playwright install chromium
npm run build
npm run lint
npm run test:browser
```

审计脚本默认检查 `http://127.0.0.1:8000`；浏览器脚本默认检查
`http://127.0.0.1:5173`，可用 `PAPERICO_TEST_URL` 覆盖。浏览器检查会打开本地论文，
因此会正常更新“最近阅读”时间，但不会上传、删除论文或发送模型请求。

记录在 `docs/verification/`：

- `pdf-audit.json`：逐篇源文件哈希与 API 校验。
- `browser-checks.json`、`browser-tests.log`：交互与响应式检查。
- `backend-tests.log`、`frontend-build.log`、`frontend-lint.log`：构建和测试记录。
- `library-desktop.png`、`library-mobile.png`、`library-dark.png`：论文库截图。
- `home-desktop.png`、`reader-desktop.png`、`reader-text.png`：工作台与阅读器截图。
