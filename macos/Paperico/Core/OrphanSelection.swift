import Foundation

/// 孤儿文件勾选与确认的状态机，抽出单独测。
///
/// 这段 UI 逻辑原先内联在 `LibraryManagementSheet`（app-only 文件，不在 SwiftPM target
/// 内），但它是**误删风险的唯一防线**，三条规则必须可测：
///
/// 1. 报告刷新后，勾选项必须与新报告取交集——否则"确认删除"会作用在已经不在列表里的条目上；
/// 2. 勾选集合为空时，确认态必须自动解除；
/// 3. 任何勾选变化都要解除确认态——不能让上一次点过"确认"的按钮在改选后继续有效。
struct OrphanSelection: Equatable {

    private(set) var selectedIds: Set<String> = []
    private(set) var isConfirming = false
    /// 进入确认态时的目标集合。删除前必须与当前集合完全一致。
    private var confirmedTargets: Set<String> = []

    init() {}

    /// 报告刷新：丢弃已消失的勾选，并**无条件解除确认态**。
    ///
    /// 即便刷新后集合没变也要重新确认：报告背后是磁盘，磁盘可能已经被别处改动
    /// （用户手动清理、另一窗口操作），而"确认删除"承诺的是"删掉我看到的那几项"。
    /// 目标集合只要发生过任何变化就沿用旧确认，就是在替用户做决定。
    mutating func refresh(available: [OrphanEntry]) {
        selectedIds.formIntersection(Set(available.map(\.id)))
        isConfirming = false
        confirmedTargets = []
    }

    /// 勾选状态变化。**任何变化都解除确认**，防止确认态跨选择残留。
    mutating func setSelected(_ isSelected: Bool, for entry: OrphanEntry) {
        if isSelected { selectedIds.insert(entry.id) } else { selectedIds.remove(entry.id) }
        isConfirming = false
        confirmedTargets = []
    }

    /// 第一步：请求确认。只有确有勾选时才可能进入确认态。
    mutating func requestConfirmation() {
        guard !selectedIds.isEmpty else { return }
        isConfirming = true
        confirmedTargets = selectedIds
    }

    mutating func clear() {
        selectedIds.removeAll()
        isConfirming = false
        confirmedTargets = []
    }

    /// 第二步：目标集合。报告顺序，便于逐项展示失败原因。
    func targets(in available: [OrphanEntry]) -> [OrphanEntry] {
        available.filter { selectedIds.contains($0.id) }
    }

    /// 已确认的删除目标。**仅在确认态且目标未变时返回**，否则返回 nil——
    /// 调用方必须据此拒绝执行，而不是自行判断。
    func confirmedTargets(in available: [OrphanEntry]) -> [OrphanEntry]? {
        guard isConfirming, !confirmedTargets.isEmpty,
              confirmedTargets == Set(targets(in: available).map(\.id)) else { return nil }
        return targets(in: available)
    }
}