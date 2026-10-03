# 离线正文渲染器

`PaperDocumentView` 只负责正文与对齐的逻辑链；App 路由、论文库、工具栏、对话、持久化和
PDFKit 仍由 SwiftUI / 原生服务管理。此目录不启动网站或服务，不调用模型。

正文使用 Charter / Iowan、中文宋体的网页排版。Markdown 通过 remark 解析，KaTeX + mhchem
渲染数学和化学公式；只接受 sup/sub 原始标签，表格另走白名单。图片由原生
`paperico-image` scheme 按 block ID 读取本地文件。CSP 禁止连接外部网络；只有用户点击
HTTP(S) / mailto 链接时才交给系统打开。

生成的 `Resources/Reader/reader.js`、KaTeX CSS / 字体和第三方许可证随 App 打包，普通
Xcode 构建与运行均不需要 Node、npm 或历史 frontend 目录。修改 JS 后在此目录执行：

```bash
npm ci
npm test
npm run build
```

依赖版本固定在 package-lock.json。构建脚本同步公式字体，并汇总实际进入浏览器 bundle
的依赖许可证。HTML / reader.css 为直接编辑的源码。

remark-math 6.0.0 和 rehype-katex 7.0.1 的 npm 包未包含许可证文件，补充许可证来自
两者对应的 [remark-math 源码版本](https://github.com/remarkjs/remark-math/tree/rehype-katex%407.0.1)
根目录 `license`，保存在 `licenses/remark-math-MIT.txt`。
