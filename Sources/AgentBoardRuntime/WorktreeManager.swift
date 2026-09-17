import AgentBoardCore
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
    /// Stderr from `WorktreeRemove` hooks that exited non-zero; hook failures never abort removal.
    public var hookDiagnostics: [String]
}

public struct DiffSummary: Sendable, Equatable {
    public var filesChanged: Int
    public var insertions: Int
    public var deletions: Int
    /// Counted in `filesChanged`; git reports no line counts for them.
    public var binaryFiles: Int

    public init(filesChanged: Int = 0, insertions: Int = 0, deletions: Int = 0, binaryFiles: Int = 0) {
        self.filesChanged = filesChanged
        self.insertions = insertions
        self.deletions = deletions
        self.binaryFiles = binaryFiles
    }

    public var isEmpty: Bool { filesChanged == 0 }
}

public enum BranchDeletion: Sendable, Equatable {
    case deleted(String)
    case kept(branch: String, reason: String)
    case noSuchBranch(String)
}

/// What `mergeIntoEpic` did to the epic branch.
public enum EpicMerge: Sendable, Equatable {
    /// The task branch does not exist, so the task never committed anything.
    case nothingToMerge
    case alreadyMerged
    case fastForwarded(head: String)
    case merged(head: String)
    /// The epic branch is untouched and the temporary worktree is gone.
    case conflicted(files: [String])
    /// Something else — the integrator, usually — has the epic branch checked out.
    case skippedCheckedOut(path: String)
}

public struct WorktreeManager: Sendable {
    public static let gitPath = "/usr/bin/git"

    public var repoPath: URL
    public var worktreeRoot: URL
    public var hookSettingsURL: URL
    /// Who made which commit on a shared branch. Nil for every path that does not attribute one;
    /// `attributedCommits` then reports every commit as nobody's.
    public var commitLedger: TaskCommitStore?

    public init(
        repoPath: URL,
        worktreeRoot: URL,
        hookSettingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json"),
        commitLedger: TaskCommitStore? = nil
    ) {
        self.repoPath = repoPath
        self.worktreeRoot = worktreeRoot
        self.hookSettingsURL = hookSettingsURL
        self.commitLedger = commitLedger
    }

    /// Reuses `branch` if it already exists so a retry sees what the previous attempt built.
    public func create(name: String, branch: String, base: String) throws -> URL {
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        let path = worktreeRoot.appendingPathComponent(name)
        if try branchExists(branch) {
            try addWorktree(["worktree", "add", path.path, branch], at: path)
        } else {
            try addWorktree(["worktree", "add", path.path, "-b", branch, base], at: path)
            recordBranchBase(branch, base: base)
        }
        return path
    }

    /// Checks out an existing branch (the epic branch cut by `ensureBranch`) rather than cutting a new one.
    public func createForBranch(name: String, branch: String) throws -> URL {
        guard try branchExists(branch) else {
            throw AgentRuntimeError("cannot create a worktree for branch \(branch): no such branch in \(repoPath.path)")
        }
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        let path = worktreeRoot.appendingPathComponent(name)
        try addWorktree(["worktree", "add", path.path, branch], at: path)
        return path
    }

    /// Puts the project's own checkout on the shared branch, cutting it from `base` the first time.
    /// Throws rather than switching when the checkout carries uncommitted work or git refuses the
    /// switch — that work belongs to whoever is using the repository, and the caller falls back to
    /// a worktree instead.
    public func adoptSharedBranch(_ branch: String, from base: String) throws {
        if try currentBranch(at: repoPath) == branch { return }
        if try hasUncommittedChanges(worktree: repoPath) {
            throw AgentRuntimeError(
                "\(repoPath.path) has uncommitted changes, so it cannot be switched to \(branch)"
            )
        }
        if try branchExists(branch) {
            try gitChecked(["checkout", branch], cwd: repoPath)
        } else {
            try gitChecked(["checkout", "-b", branch, base], cwd: repoPath)
        }
    }

    /// The branch checked out at `path`, or nil when its HEAD is detached.
    public func currentBranch(at path: URL) throws -> String? {
        let result = try gitRaw(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: path)
        guard result.status == 0 else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    public func ensureBranch(_ name: String, from base: String) throws {
        if try branchExists(name) { return }
        try git(["branch", name, base])
    }

    public func branchExists(_ name: String) throws -> Bool {
        let result = try gitRaw(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], cwd: repoPath)
        return result.status == 0
    }

    /// Merges an accepted task branch into its epic branch (SPEC §5.2), without needing the epic
    /// branch to be checked out: a fast-forward moves the ref directly, and anything else borrows a
    /// temporary worktree that is removed again — with the epic branch kept — either way.
    /// A conflict aborts and leaves the epic branch exactly where it was.
    public func mergeIntoEpic(taskBranch: String, epicBranch: String, worktreeName: String) throws -> EpicMerge {
        guard try branchExists(taskBranch) else { return .nothingToMerge }
        guard try branchExists(epicBranch) else {
            throw AgentRuntimeError("cannot merge \(taskBranch): no branch \(epicBranch) in \(repoPath.path)")
        }
        let taskRef = "refs/heads/\(taskBranch)"
        let epicRef = "refs/heads/\(epicBranch)"
        if try isAncestor(taskRef, of: epicRef) { return .alreadyMerged }
        if let holder = try list().first(where: { $0.branch == epicBranch }) {
            return .skippedCheckedOut(path: holder.path.path)
        }
        if try isAncestor(epicRef, of: taskRef) {
            let head = try resolve(taskRef)
            try git(["update-ref", epicRef, head, try resolve(epicRef)])
            return .fastForwarded(head: head)
        }

        let worktree = try createForBranch(name: worktreeName, branch: epicBranch)
        defer { try? remove(path: worktree) }
        let message = "Merge \(taskBranch) into \(epicBranch)"
        let merge = try gitRaw(mergeConfig() + ["merge", "--no-ff", "--no-edit", "-m", message, taskBranch], cwd: worktree)
        guard merge.status == 0 else {
            let files = conflictedFiles(in: worktree)
            _ = try? gitRaw(["merge", "--abort"], cwd: worktree)
            return .conflicted(files: files)
        }
        return .merged(head: try headCommit(worktree: worktree))
    }

    private func conflictedFiles(in worktree: URL) -> [String] {
        guard let output = try? gitRaw(["diff", "--name-only", "--diff-filter=U"], cwd: worktree).stdout else { return [] }
        return output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A merge commit needs a committer identity and must never stop on a GPG passphrase prompt —
    /// the app has no terminal to answer one. The repository's own identity wins when it has one.
    func mergeConfig() throws -> [String] {
        var config = ["-c", "commit.gpgsign=false"]
        let email = try gitRaw(["config", "user.email"], cwd: repoPath)
        if email.status != 0 || email.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config += ["-c", "user.email=agent-board@localhost", "-c", "user.name=Agent Board"]
        }
        return config
    }

    private func resolve(_ ref: String) throws -> String {
        try gitChecked(["rev-parse", "--verify", ref], cwd: repoPath)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Git records each worktree's location in `.git/worktrees/<name>/gitdir`; only `git worktree
    /// move` rewrites that record, so a plain directory move leaves the worktree unresolvable.
    public func move(worktree: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try git(["worktree", "move", worktree.path, destination.path])
    }

    /// Never forced: git refuses the removal rather than destroying uncommitted work.
    @discardableResult
    public func remove(path: URL) throws -> WorktreeRemovalReport {
        let diagnostics = runWorktreeRemoveHooks(worktreePath: path)
        try git(["worktree", "remove", path.path])
        return WorktreeRemovalReport(hookDiagnostics: diagnostics)
    }

    /// `git branch -d` measures merged against the current checkout's HEAD, which is rarely one of
    /// `bases`, so ancestry is checked here and the ref is then dropped directly.
    public func deleteBranchIfMerged(_ branch: String, into bases: [String]) throws -> BranchDeletion {
        guard try branchExists(branch) else { return .noSuchBranch(branch) }
        if let holder = try list().first(where: { $0.branch == branch }) {
            return .kept(branch: branch, reason: "it is still checked out at \(holder.path.path)")
        }
        let known = try bases.filter { try commitExists($0) }
        guard !known.isEmpty else {
            return .kept(branch: branch, reason: "none of \(bases.joined(separator: ", ")) exist in this repository")
        }
        guard try known.contains(where: { try isAncestor("refs/heads/\(branch)", of: $0) }) else {
            return .kept(branch: branch, reason: "it is not merged into \(known.joined(separator: " or "))")
        }
        recordReapedTip(branch)
        try git(["update-ref", "-d", "refs/heads/\(branch)"])
        return .deleted(branch)
    }

    /// The ledger is best effort: it must never be the reason a branch survives or a spawn fails.
    /// Nothing outside `agentboard/<task-id>` gets an entry.
    private func recordBranchBase(_ branch: String, base: String) {
        guard let taskId = TaskBranchLedger.taskId(ofBranch: branch) else { return }
        let ref = TaskBranchLedger.baseRef(taskId: taskId)
        guard (try? refCommit(ref)) == nil, let commit = try? refCommit(base) else { return }
        _ = try? setRef(ref, to: commit)
    }

    /// Written before the ref is dropped, so a task whose work merged stays distinguishable from
    /// one that never committed. Without it both look the same: no branch.
    private func recordReapedTip(_ branch: String) {
        guard let taskId = TaskBranchLedger.taskId(ofBranch: branch),
              let tip = try? refCommit("refs/heads/\(branch)")
        else { return }
        _ = try? setRef(TaskBranchLedger.tipRef(taskId: taskId), to: tip)
    }

    public func localBranches(withPrefix prefix: String) throws -> [String] {
        try git(["for-each-ref", "--format=%(refname:short)", "refs/heads"]).stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(prefix) }
    }

    public func list() throws -> [WorktreeInfo] {
        let result = try git(["worktree", "list", "--porcelain"])
        return Self.parsePorcelain(result.stdout)
    }

    public func diffstat(worktree: URL, against base: String) throws -> String {
        try gitChecked(["diff", "--stat", "\(base)...HEAD"], cwd: worktree).stdout
    }

    public func diffSummary(worktree: URL, against base: String) throws -> DiffSummary {
        let output = try gitChecked(["diff", "--numstat", "\(base)...HEAD"], cwd: worktree).stdout
        return Self.parseNumstat(output)
    }

    public func headCommit(worktree: URL) throws -> String {
        try gitChecked(["rev-parse", "HEAD"], cwd: worktree).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Branches absent from the repo are reported as unmerged rather than raising.
    public func mergeStatus(worktree: URL, branches: [String]) throws -> [String: Bool] {
        let output = try gitChecked(["branch", "--merged", "HEAD", "--format=%(refname:short)"], cwd: worktree).stdout
        let merged = Set(
            output.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        return branches.reduce(into: [:]) { $0[$1] = merged.contains($1) }
    }

    /// True when the worktree's HEAD is reachable from none of the `bases` that exist.
    public func hasUnmergedCommits(worktree: URL, bases: [String]) throws -> Bool {
        let known = try bases.filter { try commitExists($0) }
        guard !known.isEmpty else { return true }
        return try !known.contains { try isAncestor("HEAD", of: $0, cwd: worktree) }
    }

    /// Resolves any ref — including the ledger refs outside `refs/heads` — to its commit, or nil
    /// when the ref is not there.
    public func refCommit(_ ref: String) throws -> String? {
        let result = try gitRaw(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], cwd: repoPath)
        guard result.status == 0 else { return nil }
        let commit = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit.isEmpty ? nil : commit
    }

    public func setRef(_ ref: String, to commit: String) throws {
        try git(["update-ref", ref, commit])
    }

    /// Whether `commit` is already in `ref`'s history. Both must exist.
    public func isMerged(commit: String, into ref: String) throws -> Bool {
        try isAncestor(commit, of: ref)
    }

    /// How many commits `tip` carries that `base` does not.
    public func commitCount(from base: String, to tip: String) throws -> Int {
        let output = try gitChecked(["rev-list", "--count", "\(base)..\(tip)"], cwd: repoPath).stdout
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    public func commitExists(_ rev: String) throws -> Bool {
        try gitRaw(["rev-parse", "--verify", "--quiet", "\(rev)^{commit}"], cwd: repoPath).status == 0
    }

    private func isAncestor(_ ref: String, of other: String, cwd: URL? = nil) throws -> Bool {
        let result = try gitRaw(["merge-base", "--is-ancestor", ref, other], cwd: cwd ?? repoPath)
        switch result.status {
        case 0: return true
        case 1: return false
        default:
            throw AgentRuntimeError("git merge-base --is-ancestor \(ref) \(other) exited \(result.status): \(result.stderr)")
        }
    }

    public func hasUncommittedChanges(worktree: URL) throws -> Bool {
        let status = try gitChecked(["status", "--porcelain"], cwd: worktree).stdout
        return !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `--numstat` lines are `<added>\t<deleted>\t<path>`, with `-` for both counts on a binary file.
    /// A rename is one line whose path is a `{old => new}` spec.
    static func parseNumstat(_ output: String) -> DiffSummary {
        var summary = DiffSummary()
        for rawLine in output.split(separator: "\n") {
            let fields = rawLine.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, !fields[2].isEmpty else { continue }
            summary.filesChanged += 1
            if let added = Int(fields[0]), let deleted = Int(fields[1]) {
                summary.insertions += added
                summary.deletions += deleted
            } else {
                summary.binaryFiles += 1
            }
        }
        return summary
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

    @discardableResult
    func gitChecked(_ args: [String], cwd: URL) throws -> CommandResult {
        let result = try gitRaw(args, cwd: cwd)
        guard result.status == 0 else { throw AgentRuntimeError(Self.failure(args, result)) }
        return result
    }

    /// `git worktree add` runs the repository's `post-checkout` hook and exits with the hook's
    /// status, so a repository that sets a new worktree up from that hook reports its setup failure
    /// as this command's output — including the failure a shell-unsafe worktree path causes.
    private func addWorktree(_ args: [String], at path: URL) throws {
        let result = try gitRaw(args, cwd: repoPath)
        guard result.status != 0 else { return }
        throw AgentRuntimeError(
            WorktreePathDiagnosis.explain(Self.failure(args, result), worktreePath: path.path)
        )
    }

    private static func failure(_ args: [String], _ result: CommandResult) -> String {
        "git \(args.joined(separator: " ")) exited \(result.status)\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)"
    }

    func gitRaw(_ args: [String], cwd: URL) throws -> CommandResult {
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
