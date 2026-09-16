import AgentBoardCore
import Darwin
import Foundation

/// Which session a process belonged to, kept after that session ends.
///
/// This exists because attribution by parent chain is exactly as durable as the chain: macOS has no
/// subreaper, so killing any link reparents the listener to pid 1 and no walk ever reaches the
/// session again. An orphaned dev server outlives its session by definition, so the only way to
/// name one is to have written the pairing down while the chain still held.
///
/// **Not a database table, deliberately.** Everything in `agentboard.sqlite` is board domain state:
/// portable, migrated, meaningful on any machine. A pid is none of those — it is local to this
/// machine and invalid after a reboot, and the ledger is truncated wholesale by pruning against the
/// live process table rather than migrated. A file also keeps this epic clear of
/// `AppDatabase.swift`'s migration list. It is still persisted, because an orphan that outlives an
/// app relaunch is the case a human cannot otherwise diagnose at all.
public final class PIDSessionLedger: @unchecked Sendable {
    struct Row: Codable, Equatable {
        let pid: pid_t
        let startedAtMicros: Int64
        let owner: String
        let recordedAtMillis: Int64
    }

    public static func defaultURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        SupportPaths.appSupportDir(environment: environment)
            .appendingPathComponent("listening-port-owners.json")
    }

    private let url: URL
    private let now: @Sendable () -> Int64
    private let lock = NSLock()
    private var rows: [PIDIdentity: Row]?

    public init(url: URL, now: @escaping @Sendable () -> Int64 = { .nowMillis }) {
        self.url = url
        self.now = now
    }

    public func remembered() -> [PIDIdentity: String] {
        lock.lock()
        defer { lock.unlock() }
        return loaded().mapValues(\.owner)
    }

    /// Merges what a sweep learned and drops everything whose process is no longer live under the
    /// same identity. That prune is what bounds the file and what makes a reboot clear it: after
    /// one, no recorded `(pid, start time)` matches anything, so nothing survives the first sweep.
    ///
    /// Pass `liveIdentities` from the same sweep that produced `attributions`, never a later one.
    public func record(attributions: [PIDIdentity: String], liveIdentities: Set<PIDIdentity>) {
        lock.lock()
        defer { lock.unlock() }
        var merged = loaded()
        let stamp = now()
        for (identity, owner) in attributions {
            merged[identity] = Row(
                pid: identity.pid,
                startedAtMicros: identity.startedAtMicros,
                owner: owner,
                recordedAtMillis: stamp
            )
        }
        merged = merged.filter { liveIdentities.contains($0.key) }
        rows = merged
        save(merged)
    }

    private func loaded() -> [PIDIdentity: Row] {
        if let rows { return rows }
        let decoded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Row].self, from: $0) } ?? []
        let table = Dictionary(
            decoded.map { (PIDIdentity(pid: $0.pid, startedAtMicros: $0.startedAtMicros), $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        rows = table
        return table
    }

    private func save(_ table: [PIDIdentity: Row]) {
        let ordered = table.values.sorted { ($0.pid, $0.startedAtMicros) < ($1.pid, $1.startedAtMicros) }
        guard let data = try? JSONEncoder().encode(ordered) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
