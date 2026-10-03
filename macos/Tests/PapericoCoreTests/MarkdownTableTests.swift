import XCTest
@testable import PapericoCore

final class MarkdownTableTests: XCTestCase {
    func testShortStreamedRowsKeepEveryColumn() {
        // The old renderer checked rowIndex < row.count, then read
        // row[columnIndex]. A two-cell second row could crash on column 3.
        let table = MarkdownTable(rows: [["方法", "优势", "局限"], ["ACA", "悬崖敏感"], ["GNN"]])
        XCTAssertEqual(table.rows, [["方法", "优势", "局限"], ["ACA", "悬崖敏感", ""], ["GNN", "", ""]])
    }

    func testRowsBeyondColumnCountRemainVisible() {
        let rows = (0..<8).map { ["方法 \($0)", "结论 \($0)"] }
        XCTAssertEqual(MarkdownTable(rows: rows).rows, rows)
    }

    func testEmptyRowsAndChangingStreamWidth() {
        XCTAssertEqual(MarkdownTable(rows: []).rows, [])
        XCTAssertEqual(MarkdownTable(rows: [[]]).rows, [[]])
        XCTAssertEqual(MarkdownTable(rows: [["A"], []]).rows, [["A"], [""]])
        XCTAssertEqual(MarkdownTable(rows: [["A"], ["B", "C"]]).rows, [["A", ""], ["B", "C"]])
    }
}
