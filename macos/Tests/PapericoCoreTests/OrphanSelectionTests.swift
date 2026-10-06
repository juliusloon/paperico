import XCTest
@testable import PapericoCore

/// T7 的误删防线原先内联在 `LibraryManagementSheet`（app-only 文件），这里逐条钉住。
final class OrphanSelectionTests: XCTestCase {

    private func entry(_ path: String) -> OrphanEntry {
        OrphanEntry(path: path, kind: .paperDirectory, sizeBytes: 0)
    }

    private var report: [OrphanEntry] {
        [entry("papers/aaa"), entry("papers/bbb"), entry("mineru_output/ccc")]
    }

    func testNothingIsSelectedByDefault() {
        let selection = OrphanSelection()
        XCTAssertTrue(selection.selectedIds.isEmpty, "未引用文件默认一个都不选")
        XCTAssertFalse(selection.isConfirming)
        XCTAssertTrue(selection.targets(in: report).isEmpty)
    }

    func testSelectionTracksTheChosenEntries() {
        var selection = OrphanSelection()
        selection.setSelected(true, for: report[0])
        selection.setSelected(true, for: report[2])
        XCTAssertEqual(selection.targets(in: report).map(\.path), ["papers/aaa", "mineru_output/ccc"])
        selection.setSelected(false, for: report[0])
        XCTAssertEqual(selection.targets(in: report).map(\.path), ["mineru_output/ccc"])
    }

    /// 核心防线：确认态不得跨选择变化残留。
    func testChangingSelectionAlwaysRevokesConfirmation() {
        var selection = OrphanSelection()
        selection.setSelected(true, for: report[0])
        selection.requestConfirmation()
        XCTAssertTrue(selection.isConfirming)

        // 取消勾选 → 确认态必须解除
        selection.setSelected(false, for: report[0])
        XCTAssertFalse(selection.isConfirming)

        // 换选另一项 → 确认态同样必须解除，不能沿用上一次的确认
        selection.setSelected(true, for: report[0])
        selection.requestConfirmation()
        selection.setSelected(true, for: report[1])
        XCTAssertFalse(selection.isConfirming, "改了勾选就不能复用上一次的确认")
        XCTAssertEqual(selection.targets(in: report).map(\.path), ["papers/aaa", "papers/bbb"])
    }

    func testConfirmationRequiresASelection() {
        var selection = OrphanSelection()
        selection.requestConfirmation()
        XCTAssertFalse(selection.isConfirming, "没有勾选时不可能进入确认态")
    }

    /// 核心防线：报告刷新后，"确认删除"不得作用在已消失的条目上。
    func testRefreshDropsSelectionsThatNoLongerExist() {
        var selection = OrphanSelection()
        selection.setSelected(true, for: report[0])
        selection.setSelected(true, for: report[1])
        selection.requestConfirmation()
        XCTAssertTrue(selection.isConfirming)

        // papers/bbb 被删掉了（用户手动清理或另一处已处理）
        let afterRescan = [report[0], report[2]]
        selection.refresh(available: afterRescan)

        XCTAssertEqual(selection.selectedIds, [report[0].id])
        XCTAssertFalse(selection.isConfirming, "目标减少后必须重新确认，不能直接执行")
        XCTAssertEqual(selection.targets(in: afterRescan).map(\.path), ["papers/aaa"])
        XCTAssertNil(selection.confirmedTargets(in: afterRescan), "旧确认不得再授权删除")
    }

    func testRefreshRevokesConfirmationWhenNothingRemains() {
        var selection = OrphanSelection()
        selection.setSelected(true, for: report[0])
        selection.requestConfirmation()
        selection.refresh(available: [])
        XCTAssertTrue(selection.selectedIds.isEmpty)
        XCTAssertFalse(selection.isConfirming)
    }

    /// 即便报告内容看起来没变，刷新后也必须重新确认——报告背后是磁盘，
    /// 磁盘可能已被别处改动，沿用旧确认等于替用户做决定。
    func testRefreshAlwaysRevokesConfirmationEvenWhenReportLooksUnchanged() {
        var selection = OrphanSelection()
        selection.setSelected(true, for: report[0])
        selection.requestConfirmation()
        XCTAssertNotNil(selection.confirmedTargets(in: report))
        selection.refresh(available: report)
        XCTAssertEqual(selection.selectedIds, [report[0].id], "勾选应保留")
        XCTAssertFalse(selection.isConfirming, "确认必须重新走一遍")
        XCTAssertNil(selection.confirmedTargets(in: report))
    }

    func testClearResetsEverything() {
        var selection = OrphanSelection()
        selection.setSelected(true, for: report[0])
        selection.requestConfirmation()
        selection.clear()
        XCTAssertTrue(selection.selectedIds.isEmpty)
        XCTAssertFalse(selection.isConfirming)
    }

    /// 目标顺序跟随报告，便于逐项展示失败原因。
    func testTargetsFollowReportOrder() {
        var selection = OrphanSelection()
        selection.setSelected(true, for: report[2])
        selection.setSelected(true, for: report[0])
        XCTAssertEqual(selection.targets(in: report).map(\.path), ["papers/aaa", "mineru_output/ccc"])
    }
}