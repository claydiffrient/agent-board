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
    /// The project's teardown hook failed, timed out or could not start. Removal went ahead regardless.
    public var teardownFailure: String? = nil
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
    /// Kept because git's record of some worktree could not be read, so nothing can say it is free.
    case keptUnreadable(branch: String, record: UnreadableWorktreeRecord)
    case noSuchBranch(String)
}

/// A worktree admin file (`HEAD`, `gitdir`, rebase or bisect state) that exists but could not be read.
/// Whatever that worktree holds is unknown, so a check that meets one fails closed.
public struct UnreadableWorktreeRecord: Error, CustomStringConvertible, Sendable, Equatable {
    public var directory: String
    public var detail: String

    public var description: String {
        "git's record of a worktree in \(directory) could not be read: \(detail)"
    }
}

/// What `merge` did to the target branch — an epic branch, or the project's base branch for a
/// task that belongs to no epic.
public enum BranchMerge: Sendable, Equatable {
    /// The task branch does not exist, so the task never committed anything.
    case nothingToMerge
    case alreadyMerged
    case fastForwarded(head: String)
    case merged(head: String)
    /// The target branch is untouched.
    case conflicted(files: [String])
    /// Something has the target branch checked out — the integrator on an epic branch, or, for a
    /// base branch, the human's own checkout. Advancing the ref anyway is not an option: measured
    /// on git 2.x, `update-ref` does not refuse a checked-out branch, it moves it and leaves that
    /// working tree reporting the newly-merged files as deleted.
    case skippedCheckedOut(path: String)
    /// The target branch does not exist. Never cut for a base branch: a project whose base branch
    /// is missing is misconfigured, and inventing it would land work on a ref nobody pulls.
    case noTargetBranch(String)
}

public enum RefreshCandidate: Sendable, Equatable {
    case settled(EpicRefresh)
    case merge(previousHead: String, candidate: String)
}

public enum SlotRelease: Sendable, Equatable {
    case released
    /// The slot's directory is gone or no longer a worktree of this repository.
    case gone
    /// Uncommitted paths, as `uncommittedPaths` lists them; the slot stays leased.
    case dirty([String])
}

/// Where a branch cut from the project base starts (SPEC §3.1 step 1).
public struct BaseStartPoint: Sendable, Equatable {
    /// The remote's base commit when local `base` is behind or equal to it, otherwise `base` itself.
    public var ref: String
    /// Set when the fetch failed, so `ref` is local `base` and may be behind.
    public var warning: String?

    public init(ref: String, warning: String? = nil) {
        self.ref = ref
        self.warning = warning
    }
}

public struct WorktreeManager: Sendable {
    public static let gitPath = "/usr/bin/git"

    public var repoPath: URL
    public var worktreeRoot: URL
    public var hookSettingsURL: URL
    /// Deliberately has no default: a manager that cannot say who made a commit must say so at the
    /// construction site, because the two intents — "this one only does git plumbing" and "nobody
    /// wired the ledger" — are otherwise the same value and only one of them is correct.
    public var attribution: CommitAttributionSource
    /// Git and the repository hooks it fires run under the login-shell PATH, not launchd's (SPEC §2).
    /// Blocks on the first lookup, so only call into this type off the main thread.
    public var environment: @Sendable () -> [String: String]
    /// The project's teardown hook, run in each worktree just before `remove` deletes it.
    public var teardown: WorktreeTeardownCommand?

    public init(
        repoPath: URL,
        worktreeRoot: URL,
        hookSettingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json"),
        attribution: CommitAttributionSource,
        environment: @escaping @Sendable () -> [String: String] = { ChildEnvironment.sanitized() },
        teardown: WorktreeTeardownCommand? = nil
    ) {
        self.repoPath = repoPath
        self.worktreeRoot = worktreeRoot
        self.hookSettingsURL = hookSettingsURL
        self.attribution = attribution
        self.environment = environment
        self.teardown = teardown
    }

    /// Reuses `branch` if it already exists so a retry sees what the previous attempt built.
    public func create(name: String, branch: String, base: String) throws -> URL {
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        let path = worktreeRoot.appendingPathComponent(name)
        if try branchExists(branch) {
            try addWorktree(["worktree", "add", path.path, branch], at: path)
        } else {
            defer { if (try? branchExists(branch)) == true { recordBranchBase(branch, base: base) } }
            try addWorktree(["worktree", "add", path.path, "-b", branch, base], at: path)
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

    /// SPEC §3.1 step 2: puts pooled slot `slot` on `branch`, adding the slot's worktree the first
    /// time. `start` is where `branch` is cut when it does not exist yet. A slot already on `branch`
    /// is left as it is, and one with uncommitted changes is refused rather than carried over.
    @discardableResult
    public func occupySlot(_ slot: Int, branch: String, start: String) throws -> URL {
        let path = worktreeRoot.appendingPathComponent(WorktreeSlot.name(slot))
        guard try registeredWorktreePaths().contains(where: { Self.samePath($0, path) }) else {
            return try create(name: WorktreeSlot.name(slot), branch: branch, base: start)
        }
        if try currentBranch(at: path) == branch { return path }
        if try hasUncommittedChanges(worktree: path) {
            throw AgentRuntimeError("\(path.path) has uncommitted changes, so it cannot be switched to \(branch)")
        }
        if try branchExists(branch) {
            try gitChecked(["switch", branch], cwd: path)
        } else {
            defer { if (try? branchExists(branch)) == true { recordBranchBase(branch, base: start) } }
            try gitChecked(["switch", "-c", branch, start], cwd: path)
        }
        return path
    }

    /// SPEC §5: hands a slot back to the pool detached at its last commit, so its branch can be
    /// merged or deleted, with untracked files cleaned and ignored ones — a build directory — kept.
    /// A slot with uncommitted changes is left exactly as it is.
    public func releaseSlot(at path: URL) throws -> SlotRelease {
        guard FileManager.default.fileExists(atPath: path.path),
              try registeredWorktreePaths().contains(where: { Self.samePath($0, path) })
        else { return .gone }
        let dirty = try uncommittedPaths(worktree: path)
        guard dirty.isEmpty else { return .dirty(dirty) }
        // Detaching changes no file, so the repository's post-checkout hook has nothing to set up.
        try gitChecked(["-c", "core.hooksPath=/dev/null", "switch", "--detach"], cwd: path)
        try gitChecked(["clean", "-fd"], cwd: path)
        return .released
    }

    /// A worktree with a detached HEAD at `commit`, for a session that reads a revision and owns no branch.
    public func createDetached(name: String, commit: String) throws -> URL {
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        let path = worktreeRoot.appendingPathComponent(name)
        try addWorktree(["worktree", "add", "--detach", path.path, commit], at: path)
        return path
    }

    /// Fetches `branch` from `remote` into its remote-tracking ref and returns the commit it names
    /// there. Throws when the fetch fails, rather than answering with a stale tip.
    public func fetchRemoteTip(
        _ branch: String, remote: String = "origin", timeout: TimeInterval = baseFetchTimeout
    ) throws -> String {
        let tracking = "refs/remotes/\(remote)/\(branch)"
        let args = ["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", remote, "+refs/heads/\(branch):\(tracking)"]
        let fetched = try gitRaw(args, cwd: repoPath, timeout: timeout)
        guard fetched.status == 0 else { throw AgentRuntimeError(Self.failure(args, fetched)) }
        guard let tip = try refCommit(tracking) else {
            throw AgentRuntimeError("\(remote) has no branch \(branch)")
        }
        return tip
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
        let args = ["symbolic-ref", "--quiet", "--short", "HEAD"]
        let result = try gitRaw(args, cwd: path)
        switch result.status {
        case 0:
            let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        case 1: return nil
        default: throw AgentRuntimeError(Self.failure(args, result))
        }
    }

    public static let baseFetchTimeout: TimeInterval = 10

    /// SPEC §3.1 step 1: fetches `base` from `remote` and picks the start point for a branch cut from
    /// it. Never moves local `base`, and never throws: no remote, or a failed fetch, means local `base`,
    /// and only git's "no such remote" exit (2) goes without a warning.
    public func freshestBase(
        _ base: String, remote: String = "origin", timeout: TimeInterval = baseFetchTimeout
    ) -> BaseStartPoint {
        let tracking = "refs/remotes/\(remote)/\(base)"
        let args = ["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", remote, "+refs/heads/\(base):\(tracking)"]
        let problem: String
        do {
            let remoteURL = try gitRaw(PublishCommand.remoteURL(remote), cwd: repoPath)
            if remoteURL.status == 2 { return BaseStartPoint(ref: base) }
            guard remoteURL.status == 0 else {
                throw AgentRuntimeError(Self.failure(PublishCommand.remoteURL(remote), remoteURL))
            }
            let fetched = try gitRaw(args, cwd: repoPath, timeout: timeout)
            if fetched.status == 0 { return startPoint(local: "refs/heads/\(base)", remote: tracking, base: base) }
            let stderr = fetched.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            problem = stderr.isEmpty ? "git fetch exited \(fetched.status)" : stderr
        } catch {
            problem = "\(error)"
        }
        return BaseStartPoint(
            ref: base,
            warning: "Could not fetch \(base) from \(remote), so this branch was cut from local \(base), "
                + "which may be behind \(remote)/\(base): \(problem)"
        )
    }

    /// Behind or equal takes the remote; ahead or diverged keeps local, which holds unpushed work.
    private func startPoint(local: String, remote: String, base: String) -> BaseStartPoint {
        guard let remoteTip = try? refCommit(remote), let localTip = try? refCommit(local),
              (try? isAncestor(localTip, of: remoteTip)) == true
        else { return BaseStartPoint(ref: base) }
        return BaseStartPoint(ref: remoteTip)
    }

    /// A standalone task's recorded cut point while local `base` is still behind it (SPEC §3.1
    /// step 1), so commits the remote had are not read as the task's own; `base` otherwise.
    public func diffBase(taskId: String, base: String) -> String {
        guard let recorded = try? refCommit(TaskBranchLedger.baseRef(taskId: taskId)),
              let local = try? refCommit("refs/heads/\(base)"), local != recorded,
              (try? isAncestor(local, of: recorded)) == true
        else { return base }
        return recorded
    }

    public func ensureBranch(_ name: String, from base: String) throws {
        if try branchExists(name) { return }
        try git(["branch", name, base])
    }

    /// Exit 1 is the only "absent"; any other failure throws with git's stderr.
    public func branchExists(_ name: String) throws -> Bool {
        let args = ["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"]
        let result = try gitRaw(args, cwd: repoPath)
        if result.status == 1 { return false }
        guard result.status == 0 else { throw AgentRuntimeError(Self.failure(args, result)) }
        return true
    }

    /// What `merge` settles without writing anything — no task branch, no target, or the work is
    /// already in — and nil when a merge would have work to do.
    public func premergeOutcome(taskBranch: String, into target: String) throws -> BranchMerge? {
        guard try branchExists(taskBranch) else { return .nothingToMerge }
        guard try branchExists(target) else { return .noTargetBranch(target) }
        if try isAncestor("refs/heads/\(taskBranch)", of: "refs/heads/\(target)") { return .alreadyMerged }
        return nil
    }

    /// Merges an accepted task branch into the branch that is meant to carry it (SPEC §5, §5.2),
    /// without checking anything out: a fast-forward moves the ref, and anything else is built with
    /// `merge-tree --write-tree` and `commit-tree`, so no repository checkout hook ever runs. Either
    /// write is guarded by the target's old value. A conflict leaves the target branch where it was.
    ///
    /// The one case it will not do is a target branch some working tree holds; see
    /// `BranchMerge.skippedCheckedOut`. When a worktree's record cannot be read it throws
    /// `UnreadableWorktreeRecord` instead, and the target is untouched.
    public func merge(
        taskBranch: String,
        into target: String,
        taskTitle: String,
        targetTitle: String
    ) throws -> BranchMerge {
        if let settled = try premergeOutcome(taskBranch: taskBranch, into: target) { return settled }
        let targetRef = "refs/heads/\(target)"
        if let holder = try worktreeHolding(target) {
            return .skippedCheckedOut(path: holder)
        }
        let targetHead = try resolve(targetRef)
        let taskHead = try resolve("refs/heads/\(taskBranch)")
        let message = Self.mergeSubject(taskTitle: taskTitle, targetTitle: targetTitle)
        switch try combine(targetHead, taskHead, message: message) {
        case .fastForward:
            try git(["update-ref", "-m", "fast-forward to \(taskBranch)", targetRef, taskHead, targetHead])
            return .fastForwarded(head: taskHead)
        case .conflicted(let files):
            return .conflicted(files: files)
        case .commit(let commit):
            try git(["update-ref", "-m", "merge \(taskBranch)", targetRef, commit, targetHead])
            return .merged(head: commit)
        }
    }

    private enum Combination {
        case fastForward
        case commit(String)
        case conflicted(files: [String])
    }

    /// The commit that would carry both heads, written to the object store but to no ref.
    private func combine(_ targetHead: String, _ sourceHead: String, message: String) throws -> Combination {
        if try isAncestor(targetHead, of: sourceHead) { return .fastForward }
        let tree: String
        switch try mergeTree(targetHead, sourceHead) {
        case .conflicted(let files): return .conflicted(files: files)
        case .clean(let written): tree = written
        }
        let commit = try gitChecked(
            mergeConfig() + ["commit-tree", tree, "-p", targetHead, "-p", sourceHead, "-m", message], cwd: repoPath
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return .commit(commit)
    }

    /// One `rev-list` for both counts, so `get_epic` can afford it on every call.
    public func drift(of branch: String, from base: String) throws -> BaseDrift {
        let result = try gitRaw(
            ["rev-list", "--left-right", "--count", "refs/heads/\(base)...refs/heads/\(branch)"], cwd: repoPath
        )
        if result.status == 0 {
            let counts = result.stdout.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }
            if counts.count == 2 { return .measured(behind: counts[0], ahead: counts[1]) }
        }
        if try !branchExists(branch) { return .noEpicBranch(branch) }
        if try !branchExists(base) { return .noBaseBranch(base) }
        throw AgentRuntimeError(Self.failure(["rev-list", "--left-right", "--count", "\(base)...\(branch)"], result))
    }

    /// Where merging `base` into `branch` would leave it, without moving anything: a settled
    /// outcome, or a commit on no ref for the caller to verify and then `applyRefresh`.
    public func refreshCandidate(branch: String, base: String, message: String) throws -> RefreshCandidate {
        guard try branchExists(base) else { return .settled(.noBaseBranch) }
        guard try branchExists(branch) else { return .settled(.noEpicBranch) }
        if let holder = try list().first(where: { $0.branch == branch }) {
            return .settled(.checkedOut(path: holder.path.path, holder: nil))
        }
        let head = try resolve("refs/heads/\(branch)")
        let baseHead = try resolve("refs/heads/\(base)")
        if try isAncestor(baseHead, of: head) { return .settled(.alreadyCurrent(head: head)) }
        switch try combine(head, baseHead, message: message) {
        case .fastForward: return .merge(previousHead: head, candidate: baseHead)
        case .commit(let commit): return .merge(previousHead: head, candidate: commit)
        case .conflicted(let files): return .settled(.conflicted(head: head, files: files))
        }
    }

    /// Moves `branch` from `previousHead` to `candidate`, unless something checked it out or moved
    /// it since `refreshCandidate` looked.
    public func applyRefresh(branch: String, from previousHead: String, to candidate: String) throws -> EpicRefresh? {
        if let holder = try list().first(where: { $0.branch == branch }) {
            return .checkedOut(path: holder.path.path, holder: nil)
        }
        let ref = "refs/heads/\(branch)"
        let result = try gitRaw(["update-ref", "-m", "refresh from base", ref, candidate, previousHead], cwd: repoPath)
        guard result.status != 0 else { return nil }
        if let now = try refCommit(ref), now != previousHead { return .moved(from: previousHead, to: now) }
        throw AgentRuntimeError(Self.failure(["update-ref", ref, candidate, previousHead], result))
    }

    /// A throwaway checkout of `commit` on no branch. `git worktree add` runs the repository's
    /// `post-checkout` hook, so the timeout bounds the hook too, and stops its whole process group.
    public func createDetached(
        name: String, commit: String, timeout: TimeInterval, isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> URL {
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        let path = worktreeRoot.appendingPathComponent(name)
        var env = environment()
        env["GIT_TERMINAL_PROMPT"] = "0"
        let args = ["worktree", "add", "--detach", path.path, commit]
        let result = try BoundedCommand.run(
            executable: Self.gitPath, arguments: args, cwd: repoPath, environment: env,
            timeout: timeout, isCancelled: isCancelled
        )
        let failure: String
        switch result.ending {
        case .exited(0): return path
        case .exited(let status): failure = "git \(args.joined(separator: " ")) exited \(status)"
        case .timedOut: failure = "git \(args.joined(separator: " ")) timed out after \(Int(timeout))s and was stopped"
        case .canceled: failure = "git \(args.joined(separator: " ")) was canceled"
        }
        removeScratch(path: path)
        throw AgentRuntimeError(failure + (result.output.isEmpty ? "" : "\n\(RefreshVerifier.tail(result.output))"))
    }

    /// Scratch checkouts under `worktreeRoot` whose directory name starts with `prefix`.
    public func scratchCheckouts(prefix: String) throws -> [URL] {
        try list().map(\.path).filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    /// Forced: a scratch checkout holds build output and nobody's work.
    public func removeScratch(path: URL) {
        _ = try? gitRaw(["worktree", "remove", "--force", path.path], cwd: repoPath)
        if FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.removeItem(at: path)
            _ = try? gitRaw(["worktree", "prune"], cwd: repoPath)
        }
    }

    private enum TreeMerge {
        case clean(tree: String)
        case conflicted(files: [String])
    }

    /// `merge-tree --write-tree` needs git 2.38; macOS 14's command line tools ship 2.39. It exits 1
    /// for a conflict and for a bad argument alike, so only output that starts with a tree id is a
    /// conflict.
    private func mergeTree(_ ours: String, _ theirs: String) throws -> TreeMerge {
        let args = ["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", ours, theirs]
        let result = try gitRaw(args, cwd: repoPath)
        let fields = result.stdout.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        guard let tree = fields.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              tree.wholeMatch(of: #/[0-9a-f]{40}|[0-9a-f]{64}/#) != nil,
              result.status == 0 || result.status == 1
        else { throw AgentRuntimeError(Self.failure(args, result)) }
        if result.status == 0 { return .clean(tree: tree) }
        return .conflicted(files: fields.dropFirst().reduce(into: []) { if !$0.contains($1) { $0.append($1) } })
    }

    /// The merge commit's subject, from titles rather than branch names: this commit lands in the
    /// history of whatever repository a pull request is opened in, and `agentboard/<id>` branch
    /// names would publish the task and epic UUIDs there permanently (SPEC §5.2). For a task in no
    /// epic the target is the base branch, whose name carries no identifier and is used as written.
    public static func mergeSubject(taskTitle: String, targetTitle: String) -> String {
        let task = subjectTitle(taskTitle, fallback: "an untitled task")
        let target = subjectTitle(targetTitle, fallback: "an untitled epic")
        return "Merge \(task) into \(target)"
    }

    private static func subjectTitle(_ title: String, fallback: String) -> String {
        let collapsed = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.isEmpty ? fallback : collapsed
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

    /// Git refuses the removal rather than destroy uncommitted work. The teardown hook runs first
    /// (SPEC §3.1 "Removing a worktree"), and whatever it leaves in a worktree that was clean before
    /// it is forced past, so a hook can never be what keeps a worktree.
    @discardableResult
    public func remove(path: URL) throws -> WorktreeRemovalReport {
        var cleanBeforeTeardown = false
        var teardownFailure: String?
        // Git refuses to remove the main checkout, but only after the hook would have run in it.
        if let teardown, !Self.samePath(path, repoPath) {
            cleanBeforeTeardown = (try? hasUncommittedChanges(worktree: path)) == false
            teardownFailure = runTeardown(teardown, in: path)
        }
        let diagnostics = runWorktreeRemoveHooks(worktreePath: path)
        try git(["worktree", "remove"] + (cleanBeforeTeardown ? ["--force"] : []) + [path.path])
        return WorktreeRemovalReport(hookDiagnostics: diagnostics, teardownFailure: teardownFailure)
    }

    static let teardownOutputKept = 2_000

    /// Nil when the hook exited 0. Runs as the leader of its own process group, which a timeout kills whole.
    func runTeardown(_ teardown: WorktreeTeardownCommand, in worktree: URL) -> String? {
        var env = environment()
        env["PWD"] = worktree.path
        let label = "The teardown hook `\(teardown.command)` in \(worktree.path)"
        let result: BoundedCommand.Result
        do {
            result = try BoundedCommand.run(
                executable: "/bin/zsh", arguments: ["-c", teardown.command], cwd: worktree, environment: env,
                timeout: TimeInterval(teardown.timeoutSeconds)
            )
        } catch {
            return "\(label) could not start: \(error)"
        }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = output.isEmpty ? "" : "\nOutput:\n" + String(output.suffix(Self.teardownOutputKept))
        switch result.ending {
        case .exited(0):
            return nil
        case .exited(let status):
            return "\(label) exited \(status), so what it cleans up may still be on disk.\(tail)"
        case .timedOut, .canceled:
            return "\(label) did not finish within \(teardown.timeoutSeconds)s, so its process group was "
                + "killed and what it cleans up may still be on disk.\(tail)"
        }
    }

    /// `git status --porcelain` paths: the new name for a rename, as git shows it.
    public func uncommittedPaths(worktree: URL) throws -> [String] {
        let fields = try gitChecked(["status", "--porcelain=v1", "-z"], cwd: worktree).stdout
            .split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var paths: [String] = []
        var index = fields.startIndex
        while index < fields.endIndex {
            let entry = fields[index]
            index += 1
            guard entry.count > 3 else { continue }
            paths.append(String(entry.dropFirst(3)))
            if entry.prefix(2).contains(where: { $0 == "R" || $0 == "C" }) { index += 1 }
        }
        return paths
    }

    /// `git branch -d` measures merged against the current checkout's HEAD, which is rarely one of
    /// `bases`, so ancestry is checked here and the ref is then dropped directly — guarded by the tip
    /// that was checked, so a commit landing in between keeps the branch.
    public func deleteBranchIfMerged(_ branch: String, into bases: [String]) throws -> BranchDeletion {
        guard try branchExists(branch) else { return .noSuchBranch(branch) }
        let holder: String?
        do {
            holder = try worktreeHolding(branch)
        } catch let record as UnreadableWorktreeRecord {
            return .keptUnreadable(branch: branch, record: record)
        } catch {
            return .kept(branch: branch, reason: "whether a worktree holds it could not be read (\(error))")
        }
        if let holder {
            return .kept(branch: branch, reason: "it is still checked out at \(holder)")
        }
        let known = try bases.filter { try commitExists($0) }
        guard !known.isEmpty else {
            return .kept(branch: branch, reason: "none of \(bases.joined(separator: ", ")) exist in this repository")
        }
        let tip = try resolve("refs/heads/\(branch)")
        guard try known.contains(where: { try isAncestor(tip, of: $0) }) else {
            return .kept(branch: branch, reason: "it is not merged into \(known.joined(separator: " or "))")
        }
        recordReapedTip(branch)
        try git(["update-ref", "-d", "refs/heads/\(branch)", tip])
        return .deleted(branch)
    }

    /// The worktree whose HEAD, in-progress rebase or bisect names `branch` — the states git's own
    /// "checked out" test counts — read from git's admin files (SPEC §5). Not from `git worktree
    /// list`: that exits 0 when it cannot read a worktree's `gitdir` or `HEAD`, and leaves the
    /// worktree or its branch out. Throws `UnreadableWorktreeRecord` when any record is unreadable.
    /// A linked entry with no HEAD names nothing, as git reads it.
    private func worktreeHolding(_ branch: String) throws -> String? {
        let admins = try worktreeAdminDirectories()
        let ref = "refs/heads/\(branch)"
        for admin in [admins.common] + admins.linked {
            let head = try Self.adminFile("HEAD", in: admin, required: admin == admins.common) ?? ""
            let named = [head.replacingOccurrences(of: "ref: ", with: "")]
                + (try ["rebase-merge/head-name", "rebase-apply/head-name"].compactMap {
                    try Self.adminFile($0, in: admin, required: false)
                })
                + (try Self.adminFile("BISECT_START", in: admin, required: false).map { [$0, "refs/heads/" + $0] } ?? [])
            guard named.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == ref }) else { continue }
            if admin == admins.common { return repoPath.path }
            return try Self.worktreePath(admin: admin).path
        }
        return nil
    }

    /// Every worktree git has registered — the main checkout and each `worktrees/<id>` entry — read
    /// from the admin files rather than `git worktree list`, which drops an entry it cannot read.
    public func registeredWorktreePaths() throws -> [URL] {
        let admins = try worktreeAdminDirectories()
        return try [repoPath] + admins.linked.map { try Self.worktreePath(admin: $0) }
    }

    /// Leaves out, and prunes, every dead linked entry (`isDead`).
    private func worktreeAdminDirectories() throws -> (common: URL, linked: [URL]) {
        let (common, linked) = try linkedAdminEntries()
        return (common, try linked.filter { admin in
            guard try Self.isDead(admin) else { return true }
            try? FileManager.default.removeItem(at: admin)
            return false
        })
    }

    /// `git worktree add` refuses a path that a dead entry still registers, and does not prune it
    /// itself. Only that path's entry is touched, and one that cannot be read is left for git to refuse.
    private func pruneDeadRegistration(at path: URL) {
        guard let linked = try? linkedAdminEntries().linked else { return }
        let target = Self.canonical(path)
        for admin in linked where (try? Self.isDead(admin)) == true {
            guard let gitdir = try? Self.adminFile("gitdir", in: admin, required: false),
                  Self.canonical(Self.gitFile(gitdir, admin: admin).deletingLastPathComponent()) == target
            else { continue }
            try? FileManager.default.removeItem(at: admin)
        }
    }

    /// Resolves only the parent, which exists: git records the resolved spelling of a path that may be gone.
    private static func canonical(_ url: URL) -> String {
        url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).path
    }

    private func linkedAdminEntries() throws -> (common: URL, linked: [URL]) {
        let common = URL(fileURLWithPath: try gitChecked(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: repoPath
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        let linkedRoot = common.appendingPathComponent("worktrees")
        guard try Self.exists(linkedRoot, admin: linkedRoot) else { return (common, []) }
        let linked: [URL]
        do {
            linked = try FileManager.default
                .contentsOfDirectory(at: linkedRoot, includingPropertiesForKeys: nil)
        } catch {
            throw UnreadableWorktreeRecord(directory: linkedRoot.path, detail: error.localizedDescription)
        }
        return (common, try linked.filter { entry in
            guard let mode = try Self.mode(entry, admin: linkedRoot) else { return false }
            return mode & S_IFMT == S_IFDIR
        })
    }

    /// SPEC §5: an unlocked entry whose `gitdir` is missing or names a `.git` file that is gone —
    /// what `git worktree prune` removes. Git still refuses to check its branch out anywhere else or
    /// delete it, so it is pruned. An unreadable `gitdir` throws: whether its worktree is gone is unknown.
    private static func isDead(_ admin: URL) throws -> Bool {
        guard try !exists(admin.appendingPathComponent("locked"), admin: admin) else { return false }
        guard let gitdir = try adminFile("gitdir", in: admin, required: false) else { return true }
        return try !exists(gitFile(gitdir, admin: admin), admin: admin)
    }

    /// False only when `lstat` says the path is not there. `FileManager.fileExists` also returns
    /// false when a parent cannot be searched, which would read a live worktree as dead.
    private static func exists(_ file: URL, admin: URL) throws -> Bool {
        try mode(file, admin: admin) != nil
    }

    /// `lstat`'s mode, nil only for ENOENT or ENOTDIR; any other failure throws.
    private static func mode(_ file: URL, admin: URL) throws -> mode_t? {
        var info = stat()
        if lstat(file.path, &info) == 0 { return info.st_mode }
        let code = errno
        if code == ENOENT || code == ENOTDIR { return nil }
        throw UnreadableWorktreeRecord(directory: admin.path, detail: "\(file.path): \(String(cString: strerror(code)))")
    }

    /// Nil when an optional file is absent; a file that exists and cannot be read always throws.
    private static func adminFile(_ name: String, in admin: URL, required: Bool) throws -> String? {
        let file = admin.appendingPathComponent(name)
        guard try required || exists(file, admin: admin) else { return nil }
        do {
            return try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw UnreadableWorktreeRecord(directory: admin.path, detail: error.localizedDescription)
        }
    }

    private static func worktreePath(admin: URL) throws -> URL {
        try gitFile(adminFile("gitdir", in: admin, required: true) ?? "", admin: admin).deletingLastPathComponent()
    }

    /// `gitdir` holds the path of the worktree's `.git` file, relative to `admin` under
    /// `worktree.useRelativePaths`.
    private static func gitFile(_ gitdir: String, admin: URL) -> URL {
        let path = gitdir.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : admin.appendingPathComponent(path).standardizedFileURL
    }

    /// The ledger is best effort: it must never be the reason a branch survives or a spawn fails.
    /// Nothing outside `agentboard/<task-id>` gets an entry.
    private func recordBranchBase(_ branch: String, base: String) {
        guard let taskId = TaskBranchLedger.taskId(ofBranch: branch) else { return }
        let ref = TaskBranchLedger.baseRef(taskId: taskId)
        guard case .success(nil) = Result(catching: { try refCommit(ref) }), let commit = try? refCommit(base) else { return }
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
    public func mergeStatus(into ref: String, branches: [String]) throws -> [String: Bool] {
        let output = try git(["branch", "--merged", ref, "--format=%(refname:short)"]).stdout
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
        guard let result = try verifyCommit(ref) else { return nil }
        let commit = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit.isEmpty ? nil : commit
    }

    /// Nil only for git's "no such commit" exit (1); any other failure throws with git's output.
    private func verifyCommit(_ rev: String) throws -> CommandResult? {
        let args = ["rev-parse", "--verify", "--quiet", "\(rev)^{commit}"]
        let result = try gitRaw(args, cwd: repoPath)
        switch result.status {
        case 0: return result
        case 1: return nil
        default: throw AgentRuntimeError(Self.failure(args, result))
        }
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
        try verifyCommit(rev) != nil
    }

    /// Whether `commit`, a full object id, is in the repository, fetching it from `remote` first when
    /// it is not: a pull request's head can hold commits made on GitHub that were never fetched.
    /// A failed fetch throws with git's output; git exits 128 for an unknown commit and an
    /// unreachable remote alike.
    public func fetchCommitIfMissing(_ commit: String, from remote: String) throws -> Bool {
        guard commit.wholeMatch(of: #/[0-9a-f]{40}|[0-9a-f]{64}/#) != nil else { return false }
        if try commitExists(commit) { return true }
        try gitChecked(["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", remote, commit], cwd: repoPath)
        return try commitExists(commit)
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
                    stdin: stdin,
                    environment: environment()
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
    ///
    /// Git leaves the worktree on disk when the hook fails, and a retry adopts any worktree it finds,
    /// so a worktree this call created is removed again (the branch is kept) — SPEC §3.1 step 2.
    private func addWorktree(_ args: [String], at path: URL) throws {
        pruneDeadRegistration(at: path)
        let existed = FileManager.default.fileExists(atPath: path.path)
        let result = try gitRaw(args, cwd: repoPath)
        guard result.status != 0 else { return }
        var message = WorktreePathDiagnosis.explain(Self.failure(args, result), worktreePath: path.path)
        if !existed, (try? list())?.contains(where: { Self.samePath($0.path, path) }) == true {
            let removal = try gitRaw(["worktree", "remove", "--force", path.path], cwd: repoPath)
            if removal.status != 0 {
                message += "\n\nThe half-set-up worktree could not be removed, so a retry will adopt it: "
                    + Self.failure(["worktree", "remove", "--force", path.path], removal)
            }
        }
        throw AgentRuntimeError(message)
    }

    private static func failure(_ args: [String], _ result: CommandResult) -> String {
        "git \(args.joined(separator: " ")) exited \(result.status)\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)"
    }

    func gitRaw(_ args: [String], cwd: URL, timeout: TimeInterval) throws -> CommandResult {
        var env = environment()
        env["GIT_TERMINAL_PROMPT"] = "0"
        return try ProcessRunner.run(
            executable: URL(fileURLWithPath: Self.gitPath), arguments: args, cwd: cwd, environment: env,
            timeout: timeout
        )
    }

    func gitRaw(_ args: [String], cwd: URL) throws -> CommandResult {
        var env = environment()
        env["GIT_TERMINAL_PROMPT"] = "0"
        return try ProcessRunner.run(
            executable: URL(fileURLWithPath: Self.gitPath),
            arguments: args,
            cwd: cwd,
            environment: env
        )
    }
}
