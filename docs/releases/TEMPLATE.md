# Paperico v<VERSION>

状态：待发布。填写发布日期、App build、最低系统要求与已验证构建环境。

## 用户可见变化

- 记录最终行为、升级说明与数据流变化。

## 验证

- 运行 `./script/check.sh`，填写核心/MCP、脚本与渲染检查的通过数及 opt-in 跳过项。
- 记录最低支持系统的实机视觉冒烟；编译通过不等于实机验收通过。
- 可选真实引用验收：显式设置 `PAPERICO_E2E_QUESTIONS` 与服务配置，运行 `macos/scripts/verify_real_pipeline.sh`；详见[说明](../../macos/scripts/e2e/README.md)。
- 使用已验证支持工具与明确不支持工具的两套 provider，分别保存 `citations-agent.json` / `citations-fallback.json`；填写引用命中率（≥0.7）、伪来源（=0）、预期论文命中、答案非空率、工具轮次/调用/读取数及排名 p95（<150ms）。
- 人工验证旧库回填、Zotero 10 导出及跨论文引用定位后返回原会话；真实语料、凭据和报告不入库。

## 尚未验收

逐项列出缺失材料、负责人及证据；缺失的真实测试不得写为通过。全部发布门禁满足后才能去掉“待发布”。
