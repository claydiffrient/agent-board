import Foundation

/// What one disk cleanup did across every project: the follow-up notification (SPEC §14.4).
public struct DiskCleanupSummary: Sendable, Equatable {
    public var before: [VolumeSpace]
    public var afterSweep: [VolumeSpace]
    public var after: [VolumeSpace]
    public var removed: Int
    public var kept: Int
    /// One line per cleanup command that failed or timed out, and per project whose sweep failed.
    public var problems: [String]

    public init(
        before: [VolumeSpace], afterSweep: [VolumeSpace], after: [VolumeSpace],
        removed: Int, kept: Int, problems: [String]
    ) {
        self.before = before
        self.afterSweep = afterSweep
        self.after = after
        self.removed = removed
        self.kept = kept
        self.problems = problems
    }

    public var title: String { "Disk cleanup finished" }

    public var body: String {
        var lines = after.map { volume in
            let start = before.first { $0.mountPoint == volume.mountPoint }
            let free = DiskSpace.gigabytes(volume.availableBytes)
            return start.map { "\(volume.name): \(DiskSpace.gigabytes($0.availableBytes)) GB free before, \(free) GB after." }
                ?? "\(volume.name): \(free) GB free."
        }
        lines.append("Removed \(removed) worktree\(removed == 1 ? "" : "s"), kept \(kept).")
        lines += problems
        return lines.joined(separator: "\n")
    }

    /// Nil for a command that finished.
    public static func problem(_ result: ProjectCleanupResult, projectName: String) -> String? {
        let label = "`\(result.command)` in \(projectName)"
        switch result.outcome {
        case .exited(0): return nil
        case .exited(let status): return "\(label) exited \(status)."
        case .timedOut: return "\(label) timed out after \(result.timeoutSeconds)s."
        case .couldNotStart: return "\(label) could not start."
        }
    }
}
