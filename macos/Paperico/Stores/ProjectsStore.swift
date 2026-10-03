import Foundation
import Observation

// MARK: - ProjectsStore

@MainActor
@Observable
final class ProjectsStore {
    private let library: PaperLibrary

    var projects: [ProjectGroup] = []

    init(library: PaperLibrary) {
        self.library = library
    }

    func fetch() async {
        projects = await library.listProjects()
    }

    @discardableResult
    func create(name: String, description: String = "") async throws -> ProjectGroup {
        let created = try await library.createProject(name: name, description: description)
        projects = await library.listProjects()
        return created
    }

    func renameProject(id: String, name: String) async throws {
        guard let existing = projects.first(where: { $0.id == id }) else { return }
        _ = try await library.updateProject(id: id, name: name, description: existing.description)
        projects = await library.listProjects()
    }

    func deleteProject(id: String) async throws {
        try await library.deleteProject(id: id)
        projects = await library.listProjects()
    }
}
