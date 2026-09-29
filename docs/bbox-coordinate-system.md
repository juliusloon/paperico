# MinerU bbox 坐标系勘验(T2.3,2026-09-29)

## 结论

`content_list.json` 中每个 block 的 `bbox = [x0, y0, x1, y1]` 是**双轴各自归一化到 0–1000** 的页面相对坐标(与像素/点数无关)。

## 勘验过程

样本:活库 18 篇真实论文的 MinerU 输出(backend/app/storage/mineru_output/)。以 `011750ff04a3` 为例:

- content_list 全部 134 块均带 bbox;逐页统计 x∈[26, 977]、y∈[27, 977],上界逼近 1000;
- 同目录 `layout.json` 的 `page_size = [595, 790]`(PDF 点尺寸,即 PDF.js 的标准视口);
- content_list 首块 bbox `[62, 116, 124, 132]`,按 62/1000×595 ≈ 36.9pt 落在页边距内,符合版面。

## 换算公式

```
页面分数坐标(与缩放无关):
  left   = x0 / 1000
  top    = y0 / 1000
  width  = (x1 - x0) / 1000
  height = (y1 - y0) / 1000
```

- **Web(PDF.js)**:高亮层直接用上述分数 × 页面容器尺寸(百分比定位),无需知道点尺寸或缩放倍率。
- **原生(PDFKit)**:PDFPage.bounds 为点尺寸 `W×H`,且 **PDFKit 原点在左下角、y 轴向上**,需要翻转:
  ```
  bounds = CGRect(x: x0/1000*W, y: H - y1/1000*H, width: (x1-x0)/1000*W, height: (y1-y0)/1000*H)
  ```
- 页码:`page_idx` 从 0 计;PDF.js 从 1 计(page_num = page_idx + 1),PDFKit 的 `PDFDocument.page(at:)` 从 0 计(直接用 page_idx)。

## 兜底

老数据可能缺 bbox/page_idx( nullable):缺 bbox 时只跳页不画高亮;缺 page_idx 时不动页码。
