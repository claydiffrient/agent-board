import AgentBoardCore
import Foundation

@MainActor
enum PreviewData {
    struct Seed {
        let environment: AppEnvironment
        let project: Project
    }

    static func make() -> Seed {
        do {
            let db = try AppDatabase.inMemory()
            let project = try ProjectStore(db).register(
                name: "Sample Repo",
                repoPath: "/Users/me/Code/sample",
                baseBranch: "main",
                worktreeRoot: "/Users/me/Code/sample-worktrees",
                memoryDir: nil
            )
            let tasks = TaskStore(db)
            let running = try tasks.create(
                projectId: project.id,
                title: "Add login form validation",
                body: "Validate email and password client-side before submit.",
                acceptance: "Invalid input shows inline errors; valid input submits.",
                priority: "high",
                column: .running,
                origin: .human,
                epicId: nil
            )
            let review = try tasks.create(
                projectId: project.id,
                title: "Migrate settings page to new layout",
                body: nil,
                acceptance: "Matches the Figma frame at 1280px.",
                priority: "medium",
                column: .review,
                origin: .human,
                epicId: nil
            )
            try tasks.setBlocked(running.id, true, reason: "Waiting on permission: Bash(rm -rf build)")

            for title in ["Ship the password reset email", "Retire the legacy /v1 endpoint", "Add a health check"] {
                _ = try tasks.create(
                    projectId: project.id, title: title, body: nil, acceptance: nil, priority: nil,
                    column: .done, origin: .human, epicId: nil
                )
            }
            let done = try tasks.list(projectId: project.id, column: .done)
            try tasks.archive(ids: done.prefix(2).map(\.id))

            let sessions = SessionStore(db)
            try sessions.insert(AgentSession(
                sessionId: "3f9a1c2e-0000-4000-8000-000000000001",
                shortId: "3f9a1c2e",
                projectId: project.id,
                taskId: running.id,
                role: .worker,
                worktreePath: "\(project.worktreeRoot)/\(running.id)",
                branch: "agentboard/\(running.id)",
                cwd: "\(project.worktreeRoot)/\(running.id)",
                state: .blocked,
                startedAt: .nowMillis - 3_725_000,
                lastActivity: .nowMillis - 45_000,
                tokensIn: 41_200,
                tokensOut: 6_300,
                cacheRead: 12_000,
                estCostUSD: 0.4275,
                lastTool: "Edit"
            ))
            try sessions.insert(AgentSession(
                sessionId: "b7d2e4f6-0000-4000-8000-000000000002",
                shortId: "b7d2e4f6",
                projectId: project.id,
                taskId: review.id,
                role: .worker,
                worktreePath: "\(project.worktreeRoot)/\(review.id)",
                branch: "agentboard/\(review.id)",
                cwd: "\(project.worktreeRoot)/\(review.id)",
                state: .completed,
                startedAt: .nowMillis - 9_000_000,
                endedAt: .nowMillis - 7_200_000,
                tokensIn: 88_000,
                tokensOut: 12_400,
                estCostUSD: 1.02,
                lastTool: "Bash"
            ))

            let progress = ProgressStore(db)
            try progress.append(taskId: running.id, sessionId: "3f9a1c2e-0000-4000-8000-000000000001", kind: .status, text: "Reading existing form component")
            try progress.append(taskId: running.id, sessionId: "3f9a1c2e-0000-4000-8000-000000000001", kind: .tool, text: "Edit src/components/LoginForm.tsx")

            return Seed(environment: AppEnvironment(db: db, supervisor: StubSupervisor()), project: project)
        } catch {
            fatalError("Preview seed failed: \(error)")
        }
    }
}
