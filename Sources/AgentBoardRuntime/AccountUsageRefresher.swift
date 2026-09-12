import Foundation

/// Forces Claude Code to refetch `cachedUsageUtilization` by running `/usage` in a throwaway
/// headless session.
///
/// Strictly a fallback for a stale cache: with workers running the cache refreshes on its own, and
/// Claude Code refetches only when its own copy has aged out, so an eager call is a wasted process.
/// The run is `claude -p`, never `--bg`, so it records no `agent_session` row, is never metered as
/// project spend, and does not appear in `claude agents --json --all`.
public actor AccountUsageRefresher {
    /// Floor between attempts, successful or not, so a persistent failure cannot spawn repeatedly.
    public static let minimumInterval: TimeInterval = 10 * 60
    public static let commandTimeout: TimeInterval = 60

    /// Consecutive failures double the wait, so a CLI that is missing or permanently broken backs
    /// off to one attempt every 80 minutes instead of respawning at the floor forever.
    public static let maximumBackoffMultiplier = 3

    private var lastAttempt: Date?
    private var consecutiveFailures = 0
    private var running = false
    private let run: @Sendable (TimeInterval) async -> Bool

    public init(run: @escaping @Sendable (TimeInterval) async -> Bool = { await AccountUsageRefresher.runUsageCommand(timeout: $0) }) {
        self.run = run
    }

    /// True when a refresh actually ran. False means the rate limit or an in-flight attempt held it back.
    @discardableResult
    public func refreshIfAllowed(now: Date = .now) async -> Bool {
        guard !running else { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < currentInterval { return false }
        lastAttempt = now
        running = true
        defer { running = false }
        let succeeded = await run(Self.commandTimeout)
        consecutiveFailures = succeeded ? 0 : min(consecutiveFailures + 1, Self.maximumBackoffMultiplier)
        return succeeded
    }

    var currentInterval: TimeInterval {
        Self.minimumInterval * pow(2, Double(consecutiveFailures))
    }

    public static func runUsageCommand(timeout: TimeInterval) async -> Bool {
        let invocation = ClaudeCLI.invocation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.prefix + [
            "-p", "/usage",
            "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            "--output-format", "json",
        ]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.environment = ChildEnvironment.sanitized()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        return await withCheckedContinuation { continuation in
            let resumed = ResumeGuard()
            process.terminationHandler = { finished in
                resumed.resumeOnce(continuation, with: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                resumed.resumeOnce(continuation, with: false)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}

private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resumeOnce(_ continuation: CheckedContinuation<Bool, Never>, with value: Bool) {
        lock.lock()
        let alreadyDone = done
        done = true
        lock.unlock()
        guard !alreadyDone else { return }
        continuation.resume(returning: value)
    }
}
