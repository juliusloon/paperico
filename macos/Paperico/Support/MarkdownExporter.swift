import AppKit
import UniformTypeIdentifiers

/// Owns the native save panel and writes only to the location chosen by the user.
@MainActor
enum MarkdownExporter {
    static func export(_ note: Note) async throws {
        let panel = NSSavePanel()
        panel.title = "导出阅读笔记"
        panel.prompt = "导出"
        panel.allowedContentTypes = [UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = (title.isEmpty ? "paper-note" : title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")) + ".md"

        let response = await withCheckedContinuation { continuation in
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        guard response == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try Data(note.markdownContent.utf8).write(to: url, options: .atomic)
    }
}
