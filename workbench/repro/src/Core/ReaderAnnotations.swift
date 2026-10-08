import Foundation

enum ReaderNoteFormatting {
    struct Edit {
        let value: String
        let selection: NSRange
    }
    static func toggle(_ value: String, selection: NSRange, marker: String) -> Edit {
        let source = value as NSString, length = marker.utf16.count
        guard length > 0, selection.location <= source.length,
              selection.length <= source.length - selection.location else { return Edit(value: value, selection: selection) }
        let selected = source.substring(with: selection)
        if selection.location >= length, NSMaxRange(selection) + length <= source.length,
           source.substring(with: NSRange(location: selection.location - length, length: length)) == marker,
           source.substring(with: NSRange(location: NSMaxRange(selection), length: length)) == marker {
            let range = NSRange(location: selection.location - length, length: selection.length + 2 * length)
            return Edit(value: source.replacingCharacters(in: range, with: selected),
                        selection: NSRange(location: range.location, length: selection.length))
        }
        if selected.utf16.count >= 2 * length, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            return Edit(value: source.replacingCharacters(in: selection, with: inner),
                        selection: NSRange(location: selection.location, length: inner.utf16.count))
        }
        return Edit(value: source.replacingCharacters(in: selection, with: marker + selected + marker),
                    selection: NSRange(location: selection.location + length, length: selection.length))
    }
}

/// User annotations stay separate from generated parser/analysis blocks.
struct ReaderNodeAnnotation: Codable, Equatable, Sendable {
    var title: String? = nil
    var note: String = ""
    var isEmpty: Bool { title == nil && note.isEmpty }
}

struct ReaderAnnotationDraft: Equatable, Sendable {
    private(set) var saved: [String: ReaderNodeAnnotation] = [:]
    private(set) var values: [String: ReaderNodeAnnotation] = [:]
    private var undoHistory: [[String: ReaderNodeAnnotation]] = []
    private var redoHistory: [[String: ReaderNodeAnnotation]] = []
    var isDirty: Bool { values != saved }
    var canUndo: Bool { !undoHistory.isEmpty }
    var canRedo: Bool { !redoHistory.isEmpty }

    mutating func load(_ annotations: [String: ReaderNodeAnnotation]) {
        saved = annotations; values = annotations; undoHistory = []; redoHistory = []
    }
    mutating func set(_ annotation: ReaderNodeAnnotation, for blockId: String) {
        var next = values
        next[blockId] = annotation.isEmpty ? nil : annotation
        guard next != values else { return }
        undoHistory.append(values)
        if undoHistory.count > 100 { undoHistory.removeFirst() }
        values = next; redoHistory = []
    }
    mutating func undo() {
        guard let previous = undoHistory.popLast() else { return }
        redoHistory.append(values); values = previous
    }
    mutating func redo() {
        guard let next = redoHistory.popLast() else { return }
        undoHistory.append(values); values = next
    }
    mutating func didSave(_ snapshot: [String: ReaderNodeAnnotation]) { saved = snapshot }
    mutating func discard() { load(saved) }
}
