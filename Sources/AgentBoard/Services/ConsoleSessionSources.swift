import AgentBoardCore
import AgentBoardRuntime
import Foundation

/// A project's orchestrator (SPEC §9): runs in the repository under the session pinned on the project.
@MainActor
final class ProjectOrchestratorSource: ConsoleSessionSource {
    private let projectId: String
    private let projects: ProjectStore
    private let sessions: SessionStore
    private let grants: TokenGrantStore
    private let reports: ReportStore
    private let sessionConfigDir: URL
    private let projectsRoot: URL
    private let claude: ClaudeInvocation

    init(projectId: String, db: AppDatabase, sessionConfigDir: URL, projectsRoot: URL, claude: ClaudeInvocation) {
        self.projectId = projectId
        projects = ProjectStore(db)
        sessions = SessionStore(db)
        grants = TokenGrantStore(db)
        reports = ReportStore(db)
        self.sessionConfigDir = sessionConfigDir
        self.projectsRoot = projectsRoot
        self.claude = claude
    }

    private func project() throws -> Project {
        guard let project = try projects.get(projectId) else { throw SupervisorError.projectNotFound(projectId) }
        return project
    }

    func resolveSession(port: Int?) throws -> String {
        let project = try project()
        guard port != nil else { throw SupervisorError.serverNotRunning }
        if let pinned = project.orchSessionId, !pinned.isEmpty { return pinned }
        let sessionId = UUID().uuidString.lowercased()
        try projects.setOrchestratorSession(project.id, sessionId: sessionId)
        return sessionId
    }

    func prepareLaunch(sessionId: String, port: Int) throws -> InteractiveSessionCommand {
        let project = try project()
        if try sessions.get(sessionId) == nil {
            try sessions.insert(AgentSession(
                sessionId: sessionId,
                projectId: project.id,
                taskId: nil,
                role: .orchestrator,
                cwd: project.repoPath,
                state: .starting
            ))
        } else {
            try sessions.markResumed(sessionId)
            try sessions.setState(sessionId, .starting)
        }

        try grants.revokeAll(sessionId: sessionId)
        let grant = try grants.issue(projectId: project.id, scope: .orchestrator, taskId: nil)
        try grants.bind(token: grant.token, sessionId: sessionId)

        let configFiles = try SessionConfigWriter.write(
            configDir: sessionConfigDir,
            configId: "orchestrator-\(project.id)",
            port: port,
            token: grant.token,
            autoModeJSON: nil,
            extraMcpServers: nil
        )

        return InteractiveSessionCommand(
            sessionId: sessionId,
            cwd: URL(fileURLWithPath: project.repoPath),
            configFiles: configFiles,
            appendSystemPrompt: OrchestratorPrompt.systemPrompt(project: project),
            model: project.settings.defaultModel,
            strictMcpConfig: false,
            projectsRoot: projectsRoot,
            invocation: claude
        )
    }

    func pendingReports() throws -> [Report] {
        try reports.unconsumed(projectId: projectId)
    }
}

/// The Coordinator (SPEC §8.2): runs in its own folder with the human's home added, and every
/// registered repository — its checkout and its worktree root — is denied to its edit tools. The
/// deny list is rebuilt from the project list on every launch.
@MainActor
final class CoordinatorSource: ConsoleSessionSource {
    private let coordinator: CoordinatorStore
    private let projects: ProjectStore
    private let sessions: SessionStore
    private let grants: TokenGrantStore
    private let reports: ReportStore
    private let folder: URL
    private let home: URL
    private let sessionConfigDir: URL
    private let projectsRoot: URL
    private let claude: ClaudeInvocation

    init(
        db: AppDatabase, folder: URL, home: URL, sessionConfigDir: URL, projectsRoot: URL, claude: ClaudeInvocation
    ) {
        coordinator = CoordinatorStore(db)
        projects = ProjectStore(db)
        sessions = SessionStore(db)
        grants = TokenGrantStore(db)
        reports = ReportStore(db)
        self.folder = folder
        self.home = home
        self.sessionConfigDir = sessionConfigDir
        self.projectsRoot = projectsRoot
        self.claude = claude
    }

    func resolveSession(port: Int?) throws -> String {
        try CoordinatorHome.prepare(folder)
        guard port != nil else { throw SupervisorError.serverNotRunning }
        if let active = try coordinator.activeSessionId() { return active }
        let sessionId = UUID().uuidString.lowercased()
        try sessions.insert(AgentSession(
            sessionId: sessionId, projectId: "", role: .coordinator, cwd: folder.path, state: .starting
        ))
        try coordinator.setActiveSession(sessionId)
        return sessionId
    }

    /// `resolveSession` wrote the row, since the pin references it.
    func prepareLaunch(sessionId: String, port: Int) throws -> InteractiveSessionCommand {
        try sessions.markResumed(sessionId)
        try sessions.setState(sessionId, .starting)

        try grants.revokeAll(sessionId: sessionId)
        let grant = try grants.issueCoordinator()
        try grants.bind(token: grant.token, sessionId: sessionId)

        let configFiles = try SessionConfigWriter.write(
            configDir: sessionConfigDir,
            configId: "coordinator",
            port: port,
            token: grant.token,
            autoModeJSON: nil,
            extraMcpServers: nil
        )

        let registered = try projects.list()
        return InteractiveSessionCommand(
            sessionId: sessionId,
            cwd: folder,
            configFiles: configFiles,
            appendSystemPrompt: CoordinatorPrompt.systemPrompt(readOnlyRepos: registered.map(\.repoPath)),
            model: try coordinator.model(),
            strictMcpConfig: false,
            addDirs: [home.path],
            disallowedTools: CoordinatorHome.denyRules(
                readOnlyPaths: registered.flatMap { [$0.repoPath, $0.worktreeRoot] }
            ),
            projectsRoot: projectsRoot,
            invocation: claude
        )
    }

    func pendingReports() throws -> [Report] {
        try reports.unconsumedForCoordinator()
    }
}
