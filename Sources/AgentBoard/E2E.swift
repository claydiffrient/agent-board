import AgentBoardCore
import Foundation

/// Headless M1 pipeline check, driven by AGENTBOARD_E2E_REPO. Spawns one real worker.
@MainActor
enum E2E {
    static func run(_ env: AppEnvironment, repo: URL) async {
        do {
            try await drive(env, repo: repo)
            print("E2E PASS")
            exit(0)
        } catch {
            print("E2E FAIL: \(error)  lastError=\(env.supervisor.lastError ?? "-")")
            exit(1)
        }
    }

    private static func drive(_ env: AppEnvironment, repo: URL) async throws {
        let supervisor = env.supervisor
        while supervisor.serverPort == nil { try await _Concurrency.Task.sleep(for: .milliseconds(100)) }
        print("server port \(supervisor.serverPort!)")

        let projects = ProjectStore(env.db)
        let project: Project
        if let existing = try projects.byRepoPath(repo.path) {
            project = existing
        } else {
            project = try await supervisor.registerProject(repoPath: repo, name: "e2e", baseBranch: nil)
        }
        print("project \(project.id) base=\(project.baseBranch) worktrees=\(project.worktreeRoot)")

        let tasks = TaskStore(env.db)
        let task = try tasks.create(
            projectId: project.id,
            title: "Add hello.txt",
            body: "Create a file named hello.txt at the repo root containing the single line `hello`. Commit it. Do nothing else.",
            acceptance: "hello.txt exists on the branch with content `hello` and is committed.",
            priority: "normal", column: .ready, origin: .human, epicId: nil)
        print("task \(task.id) in \(task.column.rawValue)")

        try await supervisor.assign(taskId: task.id)
        let setupRow = try SessionStore(env.db).forTask(task.id).first!
        check("worktree exists before setup finishes", FileManager.default.fileExists(atPath: setupRow.worktreePath ?? "/nonexistent"))
        check("task is running before setup finishes", try tasks.get(task.id)?.column == .running)
        check("session is in setup", setupRow.state == .setup)

        await supervisor.waitForSetup()
        let session = try SessionStore(env.db).forTask(task.id).first!
        print("assigned session=\(session.sessionId) short=\(session.shortId ?? "?") state=\(session.state.rawValue) worktree=\(session.worktreePath ?? "?")")
        check("setup resolved into a real session", session.sessionId != setupRow.sessionId && session.state != .setup)

        let deadline = Date().addingTimeInterval(300)
        var last = ""
        while Date() < deadline {
            try await _Concurrency.Task.sleep(for: .seconds(5))
            let t = try tasks.get(task.id)!
            let s = try SessionStore(env.db).get(session.sessionId)!
            let line = "  column=\(t.column.rawValue) blocked=\(t.blocked) failed=\(t.failed) session=\(s.state.rawValue) tokens=\(s.totalTokens) cost=\(String(format: "%.4f", s.estCostUSD)) lastTool=\(s.lastTool ?? "-")"
            if line != last { print(line); last = line }
            if t.column == .review || t.failed { break }
        }
        let finalTask = try tasks.get(task.id)!
        let finalSession = try SessionStore(env.db).get(session.sessionId)!
        check("task reached review", finalTask.column == .review)
        check("session completed", finalSession.state == .completed)
        check("spend metered", finalSession.totalTokens > 0)
        check("transcript path recorded", finalSession.transcriptPath != nil)
        let reports = try ReportStore(env.db).unconsumed(projectId: project.id)
        check("report queued", reports.contains { $0.taskId == task.id && $0.kind == .complete })
        print("report body: \(reports.first { $0.taskId == task.id }?.body ?? "-")")
        let progress = try ProgressStore(env.db).list(taskId: task.id, limit: 50)
        print("progress rows: \(progress.count) kinds=\(Set(progress.map { $0.kind.rawValue }).sorted())")
        var hooks = try HookEventStore(env.db).recent(sessionId: session.sessionId, limit: 200)
        for _ in 0..<12 where !hooks.contains(where: { $0.event == "Stop" }) {
            try await _Concurrency.Task.sleep(for: .seconds(5))
            hooks = try HookEventStore(env.db).recent(sessionId: session.sessionId, limit: 200)
        }
        print("hook events: \(Set(hooks.map { $0.event }).sorted())")
        check("SessionStart hook seen", hooks.contains { $0.event == "SessionStart" })
        check("Stop hook seen", hooks.contains { $0.event == "Stop" })

        let diff = await supervisor.worktreeDiffstat(taskId: task.id)
        print("diffstat:\n\(diff ?? "-")")
        check("diffstat mentions hello.txt", diff?.contains("hello.txt") == true)

        await supervisor.reconcile(projectId: project.id)
        let merge = try run(
            "/usr/bin/git",
            ["-c", "user.email=e2e@example.com", "-c", "user.name=E2E", "-c", "commit.gpgsign=false",
             "merge", "--no-ff", "-m", "Merge task", "agentboard/\(task.id)"],
            cwd: repo
        )
        print("merge:\n\(merge)")
        try await supervisor.accept(taskId: task.id)
        check("task done", try tasks.get(task.id)?.column == .done)
        check("worktree removed", !FileManager.default.fileExists(atPath: session.worktreePath ?? "/nonexistent"))
        let worktrees = try run("/usr/bin/git", ["worktree", "list"], cwd: repo)
        check("worktree unregistered", !worktrees.contains(session.worktreePath ?? "/nonexistent"))
        let branches = try run("/usr/bin/git", ["branch", "--list", "agentboard/\(task.id)"], cwd: repo)
        check("merged branch deleted", branches.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if let shortId = finalSession.shortId {
            _ = try? run("/opt/homebrew/bin/claude", ["stop", shortId], cwd: repo)
            _ = try? run("/opt/homebrew/bin/claude", ["rm", shortId], cwd: repo)
            print("cleaned up session \(shortId)")
        }
        if failures > 0 { throw E2EError.checksFailed(failures) }
    }

    private static var failures = 0

    private static func check(_ label: String, _ ok: Bool) {
        print("\(ok ? "PASS" : "FAIL")  \(label)")
        if !ok { failures += 1 }
    }

    private static func run(_ exe: String, _ args: [String], cwd: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = cwd
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    enum E2EError: Error { case checksFailed(Int) }
}
