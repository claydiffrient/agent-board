import Darwin
import Foundation

/// Who a process in the inventory belongs to (SPEC §8.7). Ids only; joining names is the caller's.
public struct ProcessOwner: Hashable, Sendable {
    public enum Role: String, Sendable, CaseIterable {
        case worker
        case reviewer
        case orchestrator
        case coordinator
        case humanShell
        /// The app itself and the helpers it runs for no one session: git, gh, verification runs.
        case agentBoard
    }

    public var role: Role
    public var projectId: String?
    public var taskId: String?
    public var sessionId: String?

    public init(role: Role, projectId: String? = nil, taskId: String? = nil, sessionId: String? = nil) {
        self.role = role
        self.projectId = projectId
        self.taskId = taskId
        self.sessionId = sessionId
    }

    public static let agentBoard = ProcessOwner(role: .agentBoard)
}

/// A session's own checkout and when the session started, for SPEC §8.5's orphan rule.
public struct WorktreeClaim: Sendable, Equatable {
    public var path: String
    public var startedAtMicros: Int64

    public init(path: String, startedAtMicros: Int64) {
        self.path = path
        self.startedAtMicros = startedAtMicros
    }
}

/// A process the board launched or controls. Its whole descendant tree goes to `owner`.
public struct InventoryRoot: Sendable, Equatable {
    /// Nil for a session with no live host whose worktree may still hold orphans.
    public var pid: pid_t?
    public var owner: ProcessOwner
    /// Nil for a shared checkout, and while another live session shares the worktree, as in §8.5.
    public var worktree: WorktreeClaim?

    public init(pid: pid_t?, owner: ProcessOwner, worktree: WorktreeClaim? = nil) {
        self.pid = pid
        self.owner = owner
        self.worktree = worktree
    }
}

public struct InventoryProcess: Sendable, Equatable, Identifiable {
    public let identity: PIDIdentity
    public let ppid: pid_t
    /// The parent when it is in the inventory under the same owner; nil at the top of an owner's tree.
    public let parent: pid_t?
    public let command: String
    public let owner: ProcessOwner
    public let isWorktreeOrphan: Bool
    public let ports: [Int]

    public var id: PIDIdentity { identity }
    public var pid: pid_t { identity.pid }
}

public struct ProcessInventory: Sendable, Equatable {
    /// Oldest first.
    public let processes: [InventoryProcess]

    public init(processes: [InventoryProcess]) {
        self.processes = processes
    }

    /// Every process at or below a root, plus §8.5's worktree orphans and their trees, each owned
    /// by the nearest root or orphan on its parent chain (SPEC §8.7).
    public static func build(
        table: ProcessTable,
        roots: [InventoryRoot],
        ports: [ListeningPort] = [],
        facts: (pid_t) -> ProcessFacts?
    ) -> ProcessInventory {
        var owners: [pid_t: ProcessOwner] = [:]
        for root in roots {
            guard let pid = root.pid, table.entries[pid] != nil, owners[pid] == nil else { continue }
            owners[pid] = root.owner
        }

        // Claims go oldest first so an orphan in a reused worktree lands on the latest session
        // that started before it.
        var orphans: Set<pid_t> = []
        for root in roots.sorted(by: { ($0.worktree?.startedAtMicros ?? 0) < ($1.worktree?.startedAtMicros ?? 0) }) {
            guard let claim = root.worktree else { continue }
            let found = SessionProcessReaper.worktreeOrphans(
                in: table, worktree: claim.path, startedAtMicros: claim.startedAtMicros, facts: facts
            )
            for pid in found where facts(pid)?.isClaude != true && (owners[pid] == nil || orphans.contains(pid)) {
                owners[pid] = root.owner
                orphans.insert(pid)
            }
        }

        let portsByPid = Dictionary(grouping: ports, by: \.pid).mapValues { $0.map(\.port).sorted() }
        var attributed: [pid_t: ProcessOwner] = [:]
        for pid in table.entries.keys {
            if let owner = table.owner(of: pid, in: owners) { attributed[pid] = owner }
        }

        let processes = attributed.compactMap { pid, owner -> InventoryProcess? in
            guard let entry = table.entries[pid] else { return nil }
            let parentOwned = owners[pid] == nil && attributed[entry.ppid] == owner
            return InventoryProcess(
                identity: PIDIdentity(pid: pid, startedAtMicros: entry.startedAtMicros),
                ppid: entry.ppid,
                parent: parentOwned ? entry.ppid : nil,
                command: entry.command,
                owner: owner,
                isWorktreeOrphan: orphans.contains(pid),
                ports: portsByPid[pid] ?? []
            )
        }
        return ProcessInventory(processes: processes.sorted {
            ($0.identity.startedAtMicros, $0.pid) < ($1.identity.startedAtMicros, $1.pid)
        })
    }
}

/// Cumulative CPU time and resident memory, as one `PROC_PIDTASKINFO` call reports them.
public struct TaskReading: Sendable, Equatable {
    public var cpuNanos: UInt64
    public var residentBytes: UInt64

    public init(cpuNanos: UInt64, residentBytes: UInt64) {
        self.cpuNanos = cpuNanos
        self.residentBytes = residentBytes
    }
}

public struct ProcessUsage: Sendable, Equatable {
    /// Nil on a process's first reading, which has no interval to divide by. 100 is one core.
    public var cpuPercent: Double?
    public var residentBytes: UInt64

    public init(cpuPercent: Double?, residentBytes: UInt64) {
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
    }
}

/// CPU % from two readings of the same `PIDIdentity`, so a reused pid starts with no history.
public struct ProcessUsageSampler: Sendable {
    private var previous: [PIDIdentity: (reading: TaskReading, atNanos: UInt64)] = [:]

    public init() {}

    /// Forgets every identity absent from `readings`.
    public mutating func sample(_ readings: [PIDIdentity: TaskReading], atNanos now: UInt64) -> [PIDIdentity: ProcessUsage] {
        var usage: [PIDIdentity: ProcessUsage] = [:]
        for (identity, reading) in readings {
            var percent: Double?
            if let last = previous[identity], now > last.atNanos, reading.cpuNanos >= last.reading.cpuNanos {
                percent = Double(reading.cpuNanos - last.reading.cpuNanos) / Double(now - last.atNanos) * 100
            }
            usage[identity] = ProcessUsage(cpuPercent: percent, residentBytes: reading.residentBytes)
        }
        previous = readings.mapValues { ($0, now) }
        return usage
    }
}

public struct SampledInventory: Sendable, Equatable {
    public let inventory: ProcessInventory
    /// Missing for a process whose task info could not be read.
    public let usage: [PIDIdentity: ProcessUsage]
    public let sampledAt: Date

    public init(inventory: ProcessInventory, usage: [PIDIdentity: ProcessUsage], sampledAt: Date) {
        self.inventory = inventory
        self.usage = usage
        self.sampledAt = sampledAt
    }
}

/// Live sampling. Readings run only while the stream is iterated; cancelling the iterating task
/// stops them, so a view that is off screen costs nothing (SPEC §8.7, §10).
public protocol ProcessSampling: Sendable {
    func samples(every interval: Duration) -> AsyncStream<SampledInventory>
}

public struct LiveProcessSampler: ProcessSampling {
    private let roots: @Sendable () async -> [InventoryRoot]
    private let ports: @Sendable () async -> [ListeningPort]

    /// The app's own pid is always a root, owned by Agent Board; `roots` supplies everything else.
    public init(
        roots: @escaping @Sendable () async -> [InventoryRoot],
        ports: @escaping @Sendable () async -> [ListeningPort] = { [] }
    ) {
        self.roots = roots
        self.ports = ports
    }

    public func samples(every interval: Duration) -> AsyncStream<SampledInventory> {
        let roots = roots
        let ports = ports
        return AsyncStream { continuation in
            let task = _Concurrency.Task.detached(priority: .utility) {
                var sampler = ProcessUsageSampler()
                while !_Concurrency.Task.isCancelled {
                    let current = await roots()
                    let listening = await ports()
                    continuation.yield(Self.sample(roots: current, ports: listening, sampler: &sampler))
                    try? await _Concurrency.Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static func sample(
        roots: [InventoryRoot],
        ports: [ListeningPort],
        sampler: inout ProcessUsageSampler
    ) -> SampledInventory {
        let inventory = ProcessInventory.build(
            table: ProcessTable.current(),
            roots: roots + [InventoryRoot(pid: getpid(), owner: .agentBoard)],
            ports: ports,
            facts: LibProc.facts
        )
        var readings: [PIDIdentity: TaskReading] = [:]
        for process in inventory.processes {
            if let reading = LibProc.taskReading(process.pid) { readings[process.identity] = reading }
        }
        let usage = sampler.sample(readings, atNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        return SampledInventory(inventory: inventory, usage: usage, sampledAt: Date())
    }
}

extension LibProc {
    /// `pti_total_user` and `pti_total_system` are Mach ticks, not nanoseconds: on Apple silicon a
    /// 1s busy loop read 21.8M of them against 885ms from `getrusage`, the 125/3 timebase.
    static func taskReading(_ pid: pid_t) -> TaskReading? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        let ticks = info.pti_total_user + info.pti_total_system
        return TaskReading(
            cpuNanos: ticks * UInt64(timebase.numer) / UInt64(timebase.denom),
            residentBytes: info.pti_resident_size
        )
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
}
