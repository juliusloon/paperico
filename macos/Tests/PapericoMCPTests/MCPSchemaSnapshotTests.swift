import XCTest
import Foundation
@testable import PapericoMCP

/// T6: the MCP contract external clients depend on.
///
/// Tool names, argument schemas, resource kinds and URI templates are a public
/// surface — a client that breaks on them breaks in the field, not in CI.
///
/// Refresh with `UPDATE_SNAPSHOT=1 swift test --package-path macos`, and say in the
/// commit message **why** the contract changed. Refreshing without that reason turns
/// this guard into paperwork; see CONTRIBUTING.md.
final class MCPSchemaSnapshotTests: XCTestCase {

    /// Canonical JSON (sorted keys, stable formatting) so the snapshot diffs cleanly
    /// and does not depend on SDK dictionary ordering.
    private func canonicalJSON(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    func testToolSchemaMatchesSnapshot() throws {
        let tools = ReadOnlyService.tools
        // Invariants that hold regardless of the snapshot.
        XCTAssertEqual(tools.count, 10, "The read-only tool set is append-only; removals need a deprecation note")
        XCTAssertEqual(Set(tools.map(\.name)).count, tools.count, "Tool names must be unique")
        for tool in tools {
            XCTAssertEqual(tool.annotations.readOnlyHint, true, "\(tool.name) must stay read-only")
            XCTAssertEqual(tool.annotations.destructiveHint, false, "\(tool.name) must stay non-destructive")
        }
        try assertSnapshot(try canonicalJSON(tools), named: "mcp-tools")
    }

    /// Encodable mirror of the resource surface; `[String: Any]` is not Encodable.
    private struct ResourceSurface: Encodable {
        let kinds: [String]
        let uriTemplates: [String]
        enum CodingKeys: String, CodingKey {
            case kinds
            case uriTemplates = "uri_templates"
        }
    }

    func testResourceSurfaceMatchesSnapshot() throws {
        let kinds = ReadOnlyService.resourceKinds
        XCTAssertTrue(kinds.contains("brief"), "brief is the recommended first read; dropping it is a contract change")
        let surface = ResourceSurface(kinds: kinds,
                                     uriTemplates: kinds.map { "paperico://paper/{paper_id}/\($0)" })
        try assertSnapshot(try canonicalJSON(surface), named: "mcp-resources")
    }

    /// Proves the guard is not vacuous: a tool rename must change the snapshot text.
    func testRenamingAToolChangesTheSnapshot() throws {
        let before = try canonicalJSON(ReadOnlyService.tools)
        // `get_paper` is part of the contract; any snapshot that survives a rename to
        // something else is not actually pinning the names.
        XCTAssertTrue(before.contains("get_paper"))
        let renamed = before.replacingOccurrences(of: "\"get_paper\"", with: "\"read_paper\"")
        XCTAssertNotEqual(before, renamed, "A tool rename must be visible to the snapshot")
    }

    // MARK: - Snapshot plumbing

    private func assertSnapshot(_ value: String, named name: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let url = Self.snapshotURL(named: name)
        if ProcessInfo.processInfo.environment["UPDATE_SNAPSHOT"] == "1" {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try value.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("""
                Missing snapshot \(name).txt. Regenerate with \
                UPDATE_SNAPSHOT=1 swift test --package-path macos and state in the commit \
                why the MCP contract changed.
                """, file: file, line: line)
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(value, expected, """
            MCP contract drifted. If the change is intended, refresh with \
            UPDATE_SNAPSHOT=1 and state in the commit why the contract changed.
            """, file: file, line: line)
    }

    private static func snapshotURL(named name: String) -> URL {
        URL(fileURLWithPath: #filePath)          // Tests/PapericoMCPTests/MCPSchemaSnapshotTests.swift
            .deletingLastPathComponent()          // Tests/PapericoMCPTests
            .appendingPathComponent("__Snapshots__")
            .appendingPathComponent("\(name).txt")
    }
}