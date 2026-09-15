import Foundation
import GRDB

/// One file in a project's own checkout, claimed by the session that is editing it.
///
/// Only a shared-checkout session takes these: a worker in its own worktree cannot collide with
/// anyone, so it never looks one up.
public struct FileLock: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "file_lock"

    public var projectId: String
    /// Repo-relative, so the same file claimed through two different absolute spellings is one lock.
    public var path: String
    public var sessionId: String
    public var taskId: String?
    public var heldSince: Int64

    public enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case path
        case sessionId = "session_id"
        case taskId = "task_id"
        case heldSince = "held_since"
    }

    public init(projectId: String, path: String, sessionId: String, taskId: String? = nil, heldSince: Int64 = .nowMillis) {
        self.projectId = projectId
        self.path = path
        self.sessionId = sessionId
        self.taskId = taskId
        self.heldSince = heldSince
    }

    public var heldSinceDate: Date { heldSince.asDate }
}

public enum FileLockOutcome: Sendable, Equatable {
    /// Taken just now, or already this session's and refreshed by nobody.
    case acquired(FileLock)
    /// Another live session holds it. The caller waits.
    case heldBy(FileLock)
}

/// What a write has to claim before it runs, how long a contender waits for it, and how long the
/// hook that does the waiting is allowed to take.
/// How long a contended write waits and how often it re-checks. Injectable so a test does not pay
/// the shipped 90 seconds.
public struct FileLockWaitPolicy: Sendable, Equatable {
    public var timeout: TimeInterval
    public var pollInterval: TimeInterval

    public init(timeout: TimeInterval, pollInterval: TimeInterval) {
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    public static let `default` = FileLockWaitPolicy(
        timeout: FileLockPolicy.waitTimeout, pollInterval: FileLockPolicy.pollInterval
    )
}

public enum FileLockPolicy {
    /// The tools that write a file. `Bash` is deliberately absent: a shell command's target is not
    /// knowable from the command text, and the guard that reads that text already exists for pushes.
    public static let lockedTools: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit"]

    /// The `PreToolUse` matcher registered for a shared-checkout session only.
    public static var toolMatcher: String { lockedTools.sorted().joined(separator: "|") }

    /// How long a contended write waits before the agent is told to report blocked.
    ///
    /// 90s is the largest number that is still comfortably under `Caps.stallSeconds` (120), so one
    /// wait can never be mistaken for a wedged worker even if the stall exemption regressed, and it
    /// is 5% of the 1800s wall-clock budget, so a waiter that gives up has nearly all of its time
    /// left to do something else. It is long enough to cover the case the wait exists for — a holder
    /// that is seconds from committing and ending — and short enough that a holder settled in for
    /// half an hour does not silently consume the contender's whole session.
    public static let waitTimeout: TimeInterval = 90

    /// Polled rather than signalled: the holder may be a detached `claude --bg` process in another
    /// app run, so there is no in-process release to wake on.
    public static let pollInterval: TimeInterval = 0.5

    /// The hook's own timeout has to outlast the wait. Measured against Claude Code 2.1.272: a hook
    /// that holds past its declared timeout is abandoned and the write **proceeds**, so a wait
    /// longer than this number is not a lock at all.
    public static var hookTimeoutSeconds: Int { Int(waitTimeout) + 30 }

    public static func locks(toolName: String?) -> Bool {
        guard let toolName else { return false }
        return lockedTools.contains(toolName)
    }

    /// The lock key for a write, or nil when the write cannot collide in the checkout: a path
    /// outside the repository, or one this session reaches through its own worktree.
    public static func key(filePath: String?, repoPath: String) -> String? {
        guard let filePath, !filePath.isEmpty else { return nil }
        let rootURL = URL(fileURLWithPath: repoPath, isDirectory: true)
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let target = URL(fileURLWithPath: filePath, relativeTo: rootURL)
            .standardizedFileURL.resolvingSymlinksInPath().path
        guard target != root else { return nil }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard target.hasPrefix(prefix) else { return nil }
        return String(target.dropFirst(prefix.count))
    }

    public static func waitReason(path: String, holder: FileLock, waited: TimeInterval) -> String {
        """
        Another agent in this shared checkout holds \(path) (session \(holder.sessionId)). \
        Agent Board waited \(Int(waited))s for it to be released and it was not. \
        Do not edit \(path) — call report_blocked saying you need \(path), which returns this task \
        to ready so it can be retried once the file is free. Work you can finish without that file \
        is still yours to finish first.
        """
    }
}
