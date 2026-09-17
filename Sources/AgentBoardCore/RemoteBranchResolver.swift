import Foundation
import GRDB

public enum RemoteNamingError: Error, CustomStringConvertible, Equatable, Sendable {
    case unusableTemplate(String)
    case noBoardRecord(branch: String, template: String)

    public var description: String {
        switch self {
        case .unusableTemplate(let raw):
            return "This project's remote branch template \"\(raw)\" is not usable: it must contain "
                + "\(RemoteBranchTemplate.slugToken) and no placeholder other than that or "
                + "\(RemoteBranchTemplate.idToken). Fix it in project settings."
        case .noBoardRecord(let branch, let template):
            return "\(branch) matches no epic or task on this board, so there is no title to name it "
                + "from. This project publishes under \"\(template)\"; push an epic or task branch, or "
                + "clear the remote branch template to publish local names unchanged."
        }
    }
}

/// SPEC §6.1. The one place a local `agentboard/…` branch is turned into the name it takes on the remote, so
/// the orchestrator's approval and the epic header's own pull-request button cannot disagree about
/// what a branch is called once it leaves the machine.
public struct RemoteBranchResolver {
    private let epics: EpicStore
    private let tasks: TaskStore

    public init(_ db: AppDatabase) {
        epics = EpicStore(db)
        tasks = TaskStore(db)
    }

    /// Nil when the project sets no template, or when `branch` is not one Agent Board owns — the
    /// base branch is the one ref on the remote that is not this feature's to rename.
    public func publishedName(branch: String, project: Project) throws -> String? {
        guard let raw = project.settings.remoteBranchTemplate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        guard PublishPolicy.isOwned(branch) else { return nil }
        guard let template = RemoteBranchTemplate(raw) else {
            throw RemoteNamingError.unusableTemplate(raw)
        }
        guard let subject = try subject(branch: branch, projectId: project.id) else {
            throw RemoteNamingError.noBoardRecord(branch: branch, template: raw)
        }
        let name = RemoteBranchNaming.publishedName(
            for: subject, among: try peers(projectId: project.id), template: template
        )
        return try RemoteRefPolicy.validate(
            published: name, template: template, baseBranch: project.baseBranch
        )
    }

    private func subject(branch: String, projectId: String) throws -> PublishableRef? {
        if let epic = try epics.list(projectId: projectId).first(where: { $0.branch == branch }) {
            return PublishableRef(id: epic.id, title: epic.title, createdAt: epic.createdAt)
        }
        let taskId = String(branch.dropFirst(PublishPolicy.ownedPrefix.count))
        guard let task = try tasks.get(taskId), task.projectId == projectId else { return nil }
        return PublishableRef(id: task.id, title: task.title, createdAt: task.createdAt)
    }

    /// Epics and tasks pooled together: they share one namespace on the remote, so an epic and a
    /// task with the same title collide with each other and not only within their own kind.
    private func peers(projectId: String) throws -> [PublishableRef] {
        let epicRefs = try epics.list(projectId: projectId)
            .map { PublishableRef(id: $0.id, title: $0.title, createdAt: $0.createdAt) }
        let taskRefs = try tasks.list(projectId: projectId, includeArchived: true)
            .map { PublishableRef(id: $0.id, title: $0.title, createdAt: $0.createdAt) }
        return epicRefs + taskRefs
    }
}
