import Foundation

public struct WorktreeInfo: Sendable, Equatable {
    public var path: URL
    public var head: String?
    public var branch: String?
    public var isBare: Bool
    public var isDetached: Bool

    public init(path: URL, head: String? = nil, branch: String? = nil, isBare: Bool = false, isDetached: Bool = false) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isBare = isBare
        self.isDetached = isDetached
    }
}

public struct WorktreeRemovalReport: Sendable, Equatable {
    public var deletedBranch: String?
    /// Stderr from `WorktreeRemove` hooks that exited non-zero; hook failures never abort removal.
    public var hookDiagnostics: [String]
}

public struct WorktreeManager: Sendable {
    public static let gitPath = "/usr/bin/git"

    public var repoPath: URL
    public var worktreeRoot: URL
    public var hookSettingsURL: URL

    public init(
        repoPath: URL,
        worktreeRoot: URL,
        hookSettingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    ) {
        self.repoPath = repoPath
        self.worktreeRoot = worktreeRoot
        self.hookSettingsURL = hookSettingsURL
    }

    /// Reuses `branch` if it already exists so a retry sees what the previous attempt built.
    public func create(name: String, branch: String, base: String) throws -> URL {
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        let path = worktreeRoot.appendingPathComponent(name)
        if try branchExists(branch) {
            try git(["worktree", "add", path.path, branch])
        } else {
            try git(["worktree", "add", path.path, "-b", branch, base])
        }
        return path
    }

    public func ensureBranch(_ name: String, from base: String) throws {
        if try branchExists(name) { return }
        try git(["branch", name, base])
    }

    public func branchExists(_ name: String) throws -> Bool {
        let result = try gitRaw(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], cwd: repoPath)
        return result.status == 0
    }

    @discardableResult
    public func remove(path: URL, deleteBranch: Bool) throws -> WorktreeRemovalReport {
        let branch = try list().first { Self.samePath($0.path, path) }?.branch
        let diagnostics = runWorktreeRemoveHooks(worktreePath: path)
        try git(["worktree", "remove", "--force", path.path])
        var deleted: String?
        if deleteBranch, let branch {
            try git(["branch", "-D", branch])
            deleted = branch
        }
        return WorktreeRemovalReport(deletedBranch: deleted, hookDiagnostics: diagnostics)
    }

    public func list() throws -> [WorktreeInfo] {
        let result = try git(["worktree", "list", "--porcelain"])
        return Self.parsePorcelain(result.stdout)
    }

    public func diffstat(worktree: URL, against base: String) throws -> String {
        try gitChecked(["diff", "--stat", "\(base)...HEAD"], cwd: worktree).stdout
    }

    public func headCommit(worktree: URL) throws -> String {
        try gitChecked(["rev-parse", "HEAD"], cwd: worktree).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func hasUncommittedChanges(worktree: URL) throws -> Bool {
        let status = try gitChecked(["status", "--porcelain"], cwd: worktree).stdout
        return !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func parsePorcelain(_ output: String) -> [WorktreeInfo] {
        var infos: [WorktreeInfo] = []
        var current: WorktreeInfo?
        func flush() {
            if let current { infos.append(current) }
            current = nil
        }
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix("worktree ") {
                flush()
                current = WorktreeInfo(path: URL(fileURLWithPath: String(line.dropFirst("worktree ".count))))
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                current?.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            } else if line == "bare" {
                current?.isBare = true
            } else if line == "detached" {
                current?.isDetached = true
            }
        }
        flush()
        return infos
    }

    static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - WorktreeRemove hooks

    struct HookCommand: Equatable {
        var command: String
        var timeout: TimeInterval?
    }

    static func worktreeRemoveHooks(settingsAt url: URL) -> [HookCommand] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let groups = hooks["WorktreeRemove"] as? [[String: Any]]
        else { return [] }

        var commands: [HookCommand] = []
        for group in groups {
            for hook in group["hooks"] as? [[String: Any]] ?? [] {
                guard hook["type"] as? String == "command", let command = hook["command"] as? String else { continue }
                commands.append(HookCommand(command: command, timeout: (hook["timeout"] as? NSNumber)?.doubleValue))
            }
        }
        return commands
    }

    static func expandTilde(_ command: String) -> String {
        guard command.hasPrefix("~") else { return command }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if command == "~" { return home }
        if command.hasPrefix("~/") { return home + command.dropFirst(1) }
        return command
    }

    private func runWorktreeRemoveHooks(worktreePath: URL) -> [String] {
        let hooks = Self.worktreeRemoveHooks(settingsAt: hookSettingsURL)
        if hooks.isEmpty { return [] }

        let payload: [String: Any] = [
            "hook_event_name": "WorktreeRemove",
            "worktree_path": worktreePath.path,
            "cwd": repoPath.path,
        ]
        guard let stdin = try? JSONSerialization.data(withJSONObject: payload) else { return [] }

        var diagnostics: [String] = []
        for hook in hooks {
            let command = Self.expandTilde(hook.command)
            do {
                let result = try ProcessRunner.run(
                    executable: URL(fileURLWithPath: "/bin/zsh"),
                    arguments: ["-lc", command],
                    cwd: repoPath,
                    stdin: stdin
                )
                if result.status != 0 {
                    diagnostics.append("WorktreeRemove hook `\(command)` exited \(result.status): \(result.stderr)")
                }
            } catch {
                diagnostics.append("WorktreeRemove hook `\(command)` failed to start: \(error)")
            }
        }
        return diagnostics
    }

    // MARK: - git plumbing

    @discardableResult
    private func git(_ args: [String]) throws -> CommandResult {
        try gitChecked(args, cwd: repoPath)
    }

    private func gitChecked(_ args: [String], cwd: URL) throws -> CommandResult {
        let result = try gitRaw(args, cwd: cwd)
        guard result.status == 0 else {
            throw AgentRuntimeError(
                "git \(args.joined(separator: " ")) exited \(result.status)\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)"
            )
        }
        return result
    }

    private func gitRaw(_ args: [String], cwd: URL) throws -> CommandResult {
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        return try ProcessRunner.run(
            executable: URL(fileURLWithPath: Self.gitPath),
            arguments: args,
            cwd: cwd,
            environment: env
        )
    }
}
