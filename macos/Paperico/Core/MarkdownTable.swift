/// A rectangular snapshot of a Markdown/HTML table, including incomplete
/// streamed rows. Render cells directly instead of subscripting a ragged row.
struct MarkdownTable: Sendable {
    let rows: [[String]]

    init(rows: [[String]]) {
        let columns = rows.map(\.count).max() ?? 0
        self.rows = rows.map { $0 + Array(repeating: "", count: columns - $0.count) }
    }
}
