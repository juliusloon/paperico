import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
enum WorkspaceDragKind: String {
    case papers, methods
    var type: UTType { UTType(exportedAs: "com.paperico.\(rawValue)", conformingTo: .data) }
}

struct WorkspaceGroupDropDelegate: DropDelegate {
    let kind: WorkspaceDragKind
    @Binding var target: String?
    let groupId: String
    let onDropIds: ([String]) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [kind.type]) }
    func dropEntered(info: DropInfo) { target = groupId }
    func dropExited(info: DropInfo) { if target == groupId { target = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
    func performDrop(info: DropInfo) -> Bool {
        target = nil
        guard let provider = info.itemProviders(for: [kind.type]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: kind.type.identifier) { data, _ in
            guard let data, let ids = try? JSONDecoder().decode([String].self, from: data), !ids.isEmpty else { return }
            Task { @MainActor in onDropIds(ids) }
        }
        return true
    }
}
#endif
