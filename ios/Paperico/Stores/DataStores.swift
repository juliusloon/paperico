import Foundation
import Observation

// MARK: - SettingsStore (mirrors useSettingsStore)

@MainActor
@Observable
final class SettingsStore {
    private let client: ApiClient

    var settings: AppSettings?
    var loading = false

    /// Invoked whenever settings are fetched or updated (appearance sync hook).
    var onSettingsApplied: (() -> Void)?

    init(client: ApiClient) {
        self.client = client
    }

    func fetch() async {
        loading = true
        defer { loading = false }
        do {
            settings = try await client.settingsGet()
            onSettingsApplied?()
        } catch {
            // Settings are optional on first launch; pages degrade to defaults.
        }
    }

    /// PUT a partial AppSettingsUpdate body (mirrors settings.update(Partial<AppSettings>)).
    func update(partial: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: partial, options: [.fragmentsAllowed])
        settings = try await client.settingsUpdate(partialBody: data)
        onSettingsApplied?()
    }

    /// Saves the single LLM profile and assigns it to every role (mirrors SettingsPage saveLLM).
    func saveLLMProfile(profile: ModelProfileCreate) async throws {
        let assignment: [String: String] = [
            "translation_and_extraction": profile.id ?? "primary",
            "logic_chain_and_summary": profile.id ?? "primary",
            "figure_vision": profile.id ?? "primary",
            "chat": profile.id ?? "primary",
            "note_synthesis": profile.id ?? "primary",
        ]
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let profileData = try encoder.encode([profile])
        let assignmentData = try JSONSerialization.data(withJSONObject: assignment)
        let body = try JSONSerialization.data(withJSONObject: [
            "model_profiles": try JSONSerialization.jsonObject(with: profileData),
            "profile_assignment": try JSONSerialization.jsonObject(with: assignmentData),
        ])
        settings = try await client.settingsUpdate(partialBody: body)
        onSettingsApplied?()
    }

    func saveMinerU(_ mineru: MinerUSettings) async throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(mineru)
        let body = try JSONSerialization.data(withJSONObject: [
            "mineru": try JSONSerialization.jsonObject(with: data),
        ])
        settings = try await client.settingsUpdate(partialBody: body)
        onSettingsApplied?()
    }

    func saveAppearance(_ appearance: AppearanceSettings) async throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(appearance)
        let body = try JSONSerialization.data(withJSONObject: [
            "appearance": try JSONSerialization.jsonObject(with: data),
        ])
        settings = try await client.settingsUpdate(partialBody: body)
        onSettingsApplied?()
    }
}

// MARK: - ProjectsStore (mirrors useProjectsStore)

@MainActor
@Observable
final class ProjectsStore {
    private let client: ApiClient

    var projects: [ProjectGroup] = []
    var loading = false

    init(client: ApiClient) {
        self.client = client
    }

    func fetch() async {
        loading = true
        defer { loading = false }
        projects = (try? await client.projectsList()) ?? projects
    }

    @discardableResult
    func create(name: String, description: String = "") async throws -> ProjectGroup {
        var payload = ProjectGroup(id: "", name: name, description: description, colorTag: "", paperCount: 0, createdAt: "")
        payload.description = description
        let created = try await client.projectsCreate(payload)
        projects.append(created)
        return created
    }

    func renameProject(id: String, name: String) async throws {
        guard let existing = projects.first(where: { $0.id == id }) else { return }
        let updated = try await client.projectsUpdate(id: id, ProjectGroup(
            id: id, name: name, description: existing.description, colorTag: existing.colorTag,
            paperCount: existing.paperCount, createdAt: existing.createdAt
        ))
        projects = projects.map { $0.id == id ? updated : $0 }
    }

    func deleteProject(id: String) async throws {
        _ = try await client.projectsDelete(id: id)
        projects.removeAll { $0.id == id }
    }
}

// MARK: - PapersStore (mirrors usePapersStore)

struct PapersFilter: Hashable, Sendable {
    var projectId: String?
    var q: String?

    var isEmpty: Bool { (projectId ?? "").isEmpty && (q ?? "").isEmpty }
}

@MainActor
@Observable
final class PapersStore {
    private let client: ApiClient

    var papers: [PaperListItem] = []
    var loading = false
    var error = ""
    var filter = PapersFilter()

    init(client: ApiClient) {
        self.client = client
    }

    func fetch(_ newFilter: PapersFilter? = nil) async {
        loading = true
        error = ""
        let f = newFilter ?? filter
        do {
            papers = try await client.papersList(projectId: f.projectId, q: f.q)
            filter = f
        } catch {
            error = ApiFailure.wrap(error).errorDescription ?? "论文库加载失败"
            filter = f
        }
    }

    func upload(fileData: Data, fileName: String, projectId: String?) async throws -> PaperListItem {
        let paper = try await client.papersUpload(fileData: fileData, fileName: fileName, projectId: projectId, sourceUrl: nil)
        papers.insert(paper, at: 0)
        return paper
    }

    func movePapers(paperIds: [String], projectId: String?) async throws {
        guard !paperIds.isEmpty else { return }
        _ = try await client.papersMove(paperIds: paperIds, projectId: projectId)
        let selected = Set(paperIds)
        if let current = filter.projectId, !current.isEmpty, current != projectId {
            papers.removeAll { selected.contains($0.id) }
        } else {
            papers = papers.map { paper in
                var p = paper
                if selected.contains(p.id) { p.projectId = projectId }
                return p
            }
        }
    }

    func renamePaper(id: String, title: String) async throws {
        let updated = try await client.papersRename(id: id, title: title)
        papers = papers.map { $0.id == id ? updated : $0 }
    }

    func deletePaper(id: String) async throws {
        _ = try await client.papersDelete(id: id)
        papers.removeAll { $0.id == id }
    }

    func setFilter(_ f: PapersFilter) { filter = f }
}
