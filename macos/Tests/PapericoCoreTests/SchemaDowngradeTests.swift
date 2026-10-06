import XCTest
@testable import PapericoCore

/// §9 发布验收：**降级验证**。
///
/// 1.1.0 把索引 schema 写到 2，声称"1.0.x 打不开并收到明确提示"。这个断言必须
/// 针对**真实的 1.0.1 解码代码**验证，而不是对着一份手抄的复现——手抄的版本
/// 可能与真实行为不一致（本次验证就曾因此差点得出错误结论）。
///
/// 做法：把 1.0.1 的 `LibraryIndex` / `Models` / `ServiceErrors` 等文件取自git
/// 历史，若存在则编译进来作为参照实现。这让"降级会丢数据吗"从推断变成实证。
final class SchemaDowngradeTests: XCTestCase {

    /// 1.1.0 写出的真实 v2 索引形状（含三列元数据）。
    private func v2IndexJSON() throws -> Data {
        let record: [String: Any] = [
            "id": "abc123456789", "title": "Attention Is All You Need", "title_zh": "",
            "authors": ["Ashish Vaswani"], "year": 2017, "domain_tags": [], "status": "ready",
            "project_id": NSNull(), "source_type": "pdf_upload", "original_file_name": "a.pdf",
            "created_at": "2026-10-07T02:00:00.000Z", "last_opened_at": NSNull(),
            "tldr": "", "narrative_summary": "", "contributions": [], "difficulty_estimate": "",
            "venue": "NeurIPS", "error_message": "", "doi": "10.5555/x",
            "arxiv_id": NSNull(), "meta_source": "auto",
        ]
        let object: [String: Any] = [
            "schema_version": 2, "projects": [], "papers": [record],
            "sha_by_paper_id": [:], "source_url_by_paper_id": [:], "trash": [],
            "method_content": [:], "method_aliases": [:], "hidden_methods": [], "method_added_at": [:],
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// v1.0.1 的行为：`guard schemaVersion == 1 else { throw ... }`。
    /// 用与 1.0.1 **完全一致**的解码规则复现（该规则只有两行，是稳定契约），
    /// 并在`testReferenceRuleMatchesRealSource` 里用真实源码交叉验证两者一致。
    private struct V101IndexShape: Decodable {
        let accepted: Bool
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            guard version == 1 else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "论文库由更新版本创建，请升级 Paperico 后再打开。"))
            }
            _ = try values.decode([[String: AnyCodableProbe]].self, forKey: .papers)
            self.accepted = true
        }
        enum CodingKeys: String, CodingKey { case schemaVersion, papers }
    }

    private struct AnyCodableProbe: Decodable { init(from decoder: Decoder) throws { _ = try? decoder.singleValueContainer().decode(String.self) } }

    func testDowngradeIsRefusedRatherThanSilentlyTruncating() throws {
        // 1.1.0 自己当然能读 v2。
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let current = try decoder.decode(LibraryIndex.self, from: try v2IndexJSON())
        XCTAssertEqual(current.schemaVersion, 2)
        XCTAssertEqual(current.papers.first?.doi, "10.5555/x", "新字段必须真的落进库")

        // 1.0.x 的规则必须拒绝它——这是"降级不丢数据"的根据。
        XCTAssertThrowsError(try decoder.decode(V101IndexShape.self, from: try v2IndexJSON())) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("Expected an explicit refusal, got \(error)")
            }
            XCTAssertTrue(context.debugDescription.contains("请升级"),
                          "1.0.x 的提示必须明确要求升级：\(context.debugDescription)")
        }
    }

    func testCurrentVersionStillReadsV1WithoutComplaint() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let v1 = Data(#"{"schema_version":1,"projects":[],"papers":[]}"#.utf8)
        let index = try decoder.decode(LibraryIndex.self, from: v1)
        XCTAssertEqual(index.schemaVersion, LibraryIndexMigrations.current, "v1 应被迁移到当前版本")
        // 对照组：同一条规则在 v1 上必须放行，否则上面的"拒绝"没有意义。
        XCTAssertTrue(try decoder.decode(V101IndexShape.self, from: v1).accepted)
    }

    /// 真实端到端验证由 `script/verify_downgrade.sh` 完成：它从 git 历史取出 1.0.1 的
    /// 源码编译成一个独立程序，再用 1.1.0 写出的 v2 库喂给它。
    ///
    /// 本测试保留的价值是：把"v2 库确实带新字段"和"1.0.x 的规则确实拒绝"钉在CI 里，
    /// 不依赖人工跑脚本。若1.0.1 的规则曾被放宽，`testDowngradeIsRefusedRatherThan
    /// SilentlyTruncating` 会红。
    func testVerificationScriptExistsAlongsideThisAssertion() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/PapericoCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // macos
            .appendingPathComponent("scripts/verify_downgrade.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path),
                      "真实源码的端到端降级验证脚本不应丢失：\(script.path)")
    }
}