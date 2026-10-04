import XCTest
@testable import PapericoCore

final class ReaderNoteFormattingTests: XCTestCase {
    func testFormattingTogglesAndPreservesUnicodeSelection() {
        for marker in ["**", "*", "=="] {
            let original = "证据 🔬 发现"
            let selection = NSRange(location: 3, length: 2)
            let applied = ReaderNoteFormatting.toggle(original, selection: selection, marker: marker)
            XCTAssertEqual(applied.value, "证据 \(marker)🔬\(marker) 发现")
            XCTAssertEqual((applied.value as NSString).substring(with: applied.selection), "🔬")
            let removed = ReaderNoteFormatting.toggle(applied.value, selection: applied.selection, marker: marker)
            XCTAssertEqual(removed.value, original)
            XCTAssertEqual(removed.selection, selection)
        }
    }
    func testFormattingCombinesStylesAndSupportsEmptyInsertion() {
        let highlight = ReaderNoteFormatting.toggle("**重点**", selection: NSRange(location: 0, length: 6), marker: "==")
        XCTAssertEqual(highlight.value, "==**重点**==")
        let remove = ReaderNoteFormatting.toggle(highlight.value, selection: NSRange(location: 0, length: 10), marker: "==")
        XCTAssertEqual(remove.value, "**重点**")
        let insert = ReaderNoteFormatting.toggle("abc", selection: NSRange(location: 1, length: 0), marker: "**")
        XCTAssertEqual(insert.value, "a****bc")
        XCTAssertEqual(insert.selection, NSRange(location: 3, length: 0))
    }
}
