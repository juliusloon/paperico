#!/usr/bin/env bash
# §9 发布验收：**降级验证**（端到端，用真实 1.0.1 源码）。
#
# 计划 §5.2 的断言是"1.1.0 写过的库 1.0.x 打不开，收到明确提示，而不是静默丢字段"。
# 这个断言必须针对真实代码验证——手抄一份 1.0.1 的解码规则来测是不可靠的，
# 抄错就会得出"降级会丢数据"的错误结论。
#
# 做法：从 git 历史取出 1.0.1 的解码源文件，编译成一个独立程序，
# 用 1.1.0 写出的 v2 库喂给它，观察它是否明确拒绝。
#
# 用法：
#   macos/scripts/verify_downgrade.sh                # 默认对比基线提交 aeb6878（1.0.1）
#   macos/scripts/verify_downgrade.sh <git-ref>      # 对比任意历史版本
set -euo pipefail

PAPERICO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REFERENCE_REF="${1:-aeb6878}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools ]] \
   && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

echo "==> 取 $REFERENCE_REF 的 1.0.x 解码源码"
for file in Core/LibraryIndex.swift Models/Models.swift Core/ServiceErrors.swift \
            Models/PaperStatus.swift Core/MethodGroup.swift; do
  target="$WORK/$(basename "$file")"
  if ! git -C "$PAPERICO_ROOT" show "$REFERENCE_REF:macos/Paperico/$file" > "$target" 2>/dev/null; then
    echo "skip: $REFERENCE_REF 没有 $file" >&2
    exit 0
  fi
done

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

// 1.1.0 写出的 v2 索引：schema_version=2，且带上三列新元数据。
let v2 = """
{"schema_version":2,"projects":[],"papers":[{
  "id":"abc123456789","title":"Attention Is All You Need","title_zh":"",
  "authors":["Ashish Vaswani"],"year":2017,"domain_tags":[],"status":"ready",
  "project_id":null,"source_type":"pdf_upload","original_file_name":"a.pdf",
  "created_at":"2026-10-07T02:00:00.000Z","last_opened_at":null,"tldr":"",
  "narrative_summary":"","contributions":[],"difficulty_estimate":"","venue":"NeurIPS",
  "error_message":"","doi":"10.5555/x","arxiv_id":null,"meta_source":"auto"}],
 "sha_by_paper_id":{}}
"""
let v1 = #"{"schema_version":1,"projects":[],"papers":[],"sha_by_paper_id":{}}"#

let decoder = JSONDecoder()
decoder.keyDecodingStrategy = .convertFromSnakeCase

// 对照组：v1 必须被接受，否则"拒绝 v2"没有说服力。
do {
    _ = try decoder.decode(LibraryIndex.self, from: Data(v1.utf8))
    print("CONTROL_OK: 1.0.x 接受 v1 库")
} catch {
    print("CONTROL_FAIL: 1.0.x 竟然拒绝了 v1 库 —— 参照实现不对")
    exit(1)
}

// 关键断言：v2 必须被明确拒绝，且提示要求升级。
do {
    _ = try decoder.decode(LibraryIndex.self, from: Data(v2.utf8))
    print("FAIL: 1.0.x 接受了 v2 库 —— 降级会静默丢弃 doi/arxiv_id/meta_source")
    exit(1)
} catch let error as PipelineError {
    guard error.message.contains("请升级") else {
        print("FAIL: 拒绝了但提示不明确：\(error.message)")
        exit(1)
    }
    print("PASS: 1.0.x 明确拒绝 v2 库 -> \(error.errorCode.rawValue) / \(error.message)")
}
SWIFT

echo "==> 编译 1.0.x 参照实现"
swiftc -o "$WORK/v101test" "$WORK"/LibraryIndex.swift "$WORK"/Models.swift "$WORK"/ServiceErrors.swift \
  "$WORK"/PaperStatus.swift "$WORK"/MethodGroup.swift "$WORK/main.swift"

echo "==> 运行"
"$WORK/v101test"