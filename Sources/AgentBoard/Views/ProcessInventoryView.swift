import AgentBoardCore
import AgentBoardRuntime
import SwiftUI

/// One line of the process table: a project, an owner within it, or a process (SPEC §10).
struct ProcessRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case group
        case owner
        case process
    }

    let id: String
    let kind: Kind
    let depth: Int
    let name: String
    let pid: pid_t?
    /// Nil on a group or owner row, which a stop cannot target.
    let identity: PIDIdentity?
    let owner: String
    /// Nil on a process's first reading and for one whose reading failed; drawn as a dash.
    let cpuPercent: Double?
    let residentBytes: UInt64?
    let startedAt: Date?
    let ports: [Int]

    var cpuSortKey: Double { cpuPercent ?? -1 }
    var memorySortKey: UInt64 { residentBytes ?? 0 }
}

struct ProcessTotals: Equatable {
    let processes: Int
    let cpuPercent: Double?
    let residentBytes: UInt64
}

/// Activity Monitor's "All Processes, Hierarchically": project, then owner, then each owner's
/// tree by the inventory's `parent`; the Coordinator and Agent Board are groups of their own.
enum ProcessRows {
    static func hierarchy(
        _ sample: SampledInventory, projectNames: [String: String], taskTitles: [String: String]
    ) -> [ProcessRow] {
        let processes = sample.inventory.processes
        let byOwner = Dictionary(grouping: processes, by: \.owner)
        let owners = byOwner.keys.sorted { lhs, rhs in
            groupOrder(lhs, projectNames) == groupOrder(rhs, projectNames)
                ? ownerOrder(lhs, byOwner) < ownerOrder(rhs, byOwner)
                : groupOrder(lhs, projectNames) < groupOrder(rhs, projectNames)
        }

        var rows: [ProcessRow] = []
        var openGroup: String?
        for owner in owners {
            let members = byOwner[owner] ?? []
            let groupId = groupKey(owner)
            let depth: Int
            if let projectId = owner.projectId, owner.role != .agentBoard, owner.role != .coordinator {
                if openGroup != groupId {
                    let inProject = owners.filter { groupKey($0) == groupId }.flatMap { byOwner[$0] ?? [] }
                    rows.append(summary(
                        id: groupId, kind: .group, depth: 0, name: projectNames[projectId] ?? "Unknown project",
                        owner: "", members: inProject, sample: sample
                    ))
                    openGroup = groupId
                }
                rows.append(summary(
                    id: ownerKey(owner), kind: .owner, depth: 1,
                    name: owner.taskId.flatMap { taskTitles[$0] } ?? roleTitle(owner.role),
                    owner: roleLabel(owner.role), members: members, sample: sample
                ))
                depth = 2
            } else {
                rows.append(summary(
                    id: ownerKey(owner), kind: .group, depth: 0, name: roleTitle(owner.role),
                    owner: "", members: members, sample: sample
                ))
                openGroup = nil
                depth = 1
            }
            let children = Dictionary(grouping: members.filter { $0.parent != nil }, by: { $0.parent! })
            func walk(_ process: InventoryProcess, _ level: Int) {
                rows.append(row(process, depth: level, projectNames: projectNames, sample: sample))
                for child in children[process.pid] ?? [] { walk(child, level + 1) }
            }
            for top in members where top.parent == nil { walk(top, depth) }
        }
        return rows
    }

    /// Sorting by a column flattens the tree, as Activity Monitor does.
    static func flat(
        _ sample: SampledInventory, projectNames: [String: String], sortedBy order: [KeyPathComparator<ProcessRow>]
    ) -> [ProcessRow] {
        sample.inventory.processes
            .map { row($0, depth: 0, projectNames: projectNames, sample: sample) }
            .sorted(using: order)
    }

    static func totals(_ sample: SampledInventory) -> ProcessTotals {
        let usage = sample.inventory.processes.compactMap { sample.usage[$0.identity] }
        let cpu = usage.compactMap(\.cpuPercent)
        return ProcessTotals(
            processes: sample.inventory.processes.count,
            cpuPercent: cpu.isEmpty ? nil : cpu.reduce(0, +),
            residentBytes: usage.reduce(0) { $0 + $1.residentBytes }
        )
    }

    static func roleLabel(_ role: ProcessOwner.Role) -> String {
        switch role {
        case .worker: "worker"
        case .reviewer: "reviewer"
        case .orchestrator: "orchestrator"
        case .coordinator: "Coordinator"
        case .humanShell: "shell"
        case .agentBoard: "Agent Board"
        }
    }

    private static func roleTitle(_ role: ProcessOwner.Role) -> String {
        switch role {
        case .worker: "Worker"
        case .reviewer: "Reviewer"
        case .orchestrator: "Orchestrator"
        case .coordinator: "Coordinator"
        case .humanShell: "Shell"
        case .agentBoard: "Agent Board"
        }
    }

    private static func row(
        _ process: InventoryProcess, depth: Int, projectNames: [String: String], sample: SampledInventory
    ) -> ProcessRow {
        let usage = sample.usage[process.identity]
        var owner = roleLabel(process.owner.role)
        if let name = process.owner.projectId.flatMap({ projectNames[$0] }), process.owner.role != .agentBoard {
            owner = "\(name) · \(owner)"
        }
        if process.isWorktreeOrphan { owner += " · orphan" }
        return ProcessRow(
            id: "pid:\(process.pid):\(process.identity.startedAtMicros)", kind: .process, depth: depth,
            name: process.command, pid: process.pid, identity: process.identity, owner: owner,
            cpuPercent: usage?.cpuPercent, residentBytes: usage?.residentBytes,
            startedAt: Date(timeIntervalSince1970: Double(process.identity.startedAtMicros) / 1_000_000),
            ports: process.ports
        )
    }

    private static func summary(
        id: String, kind: ProcessRow.Kind, depth: Int, name: String, owner: String,
        members: [InventoryProcess], sample: SampledInventory
    ) -> ProcessRow {
        let usage = members.compactMap { sample.usage[$0.identity] }
        let cpu = usage.compactMap(\.cpuPercent)
        return ProcessRow(
            id: id, kind: kind, depth: depth, name: name, pid: nil, identity: nil, owner: owner,
            cpuPercent: cpu.isEmpty ? nil : cpu.reduce(0, +),
            residentBytes: usage.isEmpty ? nil : usage.reduce(0) { $0 + $1.residentBytes },
            startedAt: nil, ports: []
        )
    }

    private static func groupKey(_ owner: ProcessOwner) -> String {
        switch owner.role {
        case .agentBoard, .coordinator: ownerKey(owner)
        default: "project:\(owner.projectId ?? "")"
        }
    }

    private static func ownerKey(_ owner: ProcessOwner) -> String {
        "owner:\(owner.role.rawValue):\(owner.projectId ?? ""):\(owner.taskId ?? ""):\(owner.sessionId ?? "")"
    }

    /// Projects by name, then the Coordinator, then Agent Board last.
    private static func groupOrder(_ owner: ProcessOwner, _ names: [String: String]) -> GroupOrder {
        switch owner.role {
        case .coordinator: GroupOrder(rank: 1, name: "", id: "")
        case .agentBoard: GroupOrder(rank: 2, name: "", id: "")
        default: GroupOrder(rank: 0, name: owner.projectId.flatMap { names[$0] } ?? "", id: owner.projectId ?? "")
        }
    }

    private static func ownerOrder(_ owner: ProcessOwner, _ byOwner: [ProcessOwner: [InventoryProcess]]) -> OwnerOrder {
        let rank = [ProcessOwner.Role.orchestrator, .humanShell, .worker, .reviewer, .coordinator, .agentBoard]
            .firstIndex(of: owner.role) ?? 0
        let first = byOwner[owner]?.first
        return OwnerOrder(rank: rank, start: first?.identity.startedAtMicros ?? 0, pid: first?.pid ?? 0)
    }

    private struct GroupOrder: Comparable {
        let rank: Int
        let name: String
        let id: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            let byName = lhs.name.localizedStandardCompare(rhs.name)
            return byName == .orderedSame ? lhs.id < rhs.id : byName == .orderedAscending
        }
    }

    private struct OwnerOrder: Comparable {
        let rank: Int
        let start: Int64
        let pid: pid_t

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.rank, lhs.start, lhs.pid) < (rhs.rank, rhs.start, rhs.pid)
        }
    }
}

enum ProcessCell {
    static func cpu(_ percent: Double?) -> String {
        percent.map { String(format: "%.1f", $0) } ?? "—"
    }

    static func memory(_ bytes: UInt64?) -> String {
        bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "—"
    }

    static func ports(_ ports: [Int]) -> String {
        ports.map { ":\($0)" }.joined(separator: ", ")
    }

    static let sessionHostsUnavailable = "Session hosts unavailable: claude agents could not be read"

    static func totals(_ totals: ProcessTotals?) -> String {
        guard let totals else { return "Sampling…" }
        let noun = totals.processes == 1 ? "1 process" : "\(totals.processes) processes"
        return "\(noun) · \(cpu(totals.cpuPercent))% CPU · \(memory(totals.residentBytes))"
    }
}

/// A stop the human has been asked to confirm, planned against the sample the row came from.
struct PendingProcessStop: Identifiable {
    let process: InventoryProcess
    let inventory: ProcessInventory
    let detail: String

    var id: PIDIdentity { process.identity }
}

/// At a Glance's Processes view. Sampling runs only while this view is mounted: `.task` iterates
/// the sampler's stream, and leaving cancels it (SPEC §8.7, §10).
struct ProcessInventoryView: View {
    let projects: [Project]

    static let interval: Duration = .seconds(2)

    @Environment(AppEnvironment.self) private var env
    @State private var sample: SampledInventory?
    @State private var taskTitles: [String: String] = [:]
    @State private var sortOrder: [KeyPathComparator<ProcessRow>] = []
    @State private var selection: ProcessRow.ID?
    @State private var pending: PendingProcessStop?

    private var projectNames: [String: String] {
        Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    private var rows: [ProcessRow] {
        guard let sample else { return [] }
        return sortOrder.isEmpty
            ? ProcessRows.hierarchy(sample, projectNames: projectNames, taskTitles: taskTitles)
            : ProcessRows.flat(sample, projectNames: projectNames, sortedBy: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Process") { row in
                    Text(row.name)
                        .fontWeight(row.kind == .process ? .regular : .semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, CGFloat(row.depth) * 14)
                        .help(row.name)
                }
                .width(min: 120, ideal: 200)
                TableColumn("PID") { row in
                    Text(row.pid.map(String.init) ?? "").monospacedDigit()
                }
                .width(min: 44, ideal: 52)
                TableColumn("Owner") { row in
                    Text(row.owner).lineLimit(1).truncationMode(.tail).help(row.owner)
                }
                .width(min: 80, ideal: 120)
                TableColumn("CPU %", value: \.cpuSortKey) { row in
                    Text(ProcessCell.cpu(row.cpuPercent)).monospacedDigit()
                }
                .width(min: 44, ideal: 58)
                TableColumn("Memory", value: \.memorySortKey) { row in
                    Text(row.kind == .process || row.residentBytes != nil ? ProcessCell.memory(row.residentBytes) : "")
                        .monospacedDigit()
                }
                .width(min: 56, ideal: 64)
                TableColumn("Uptime") { row in
                    Text(row.startedAt.map { Format.elapsed(from: $0, to: sample?.sampledAt ?? .now) } ?? "")
                        .monospacedDigit()
                }
                .width(min: 48, ideal: 56)
                TableColumn("Ports") { row in
                    Text(ProcessCell.ports(row.ports)).lineLimit(1).help(ProcessCell.ports(row.ports))
                }
                .width(min: 48, ideal: 66)
            }
            .contextMenu(forSelectionType: ProcessRow.ID.self) { ids in
                if let id = ids.first, identity(of: id) != nil {
                    Button("Stop…") { requestStop(id) }
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ProcessCell.totals(sample.map(ProcessRows.totals)))
                        .monospacedDigit()
                    if sample?.sessionHostsUnavailable == true {
                        Label(ProcessCell.sessionHostsUnavailable, systemImage: "exclamationmark.triangle")
                    }
                    if let message = env.processStops.message {
                        Text(message).lineLimit(1).help(message)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
                if !sortOrder.isEmpty {
                    Button("Show Hierarchy") { sortOrder = [] }
                }
                Button("Stop…") { if let selection { requestStop(selection) } }
                    .disabled(selectedIdentity == nil || selectedIdentity.map(env.processStops.stopping.contains) == true)
                    .help("Stop the selected process and everything under it")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .confirmationDialog(
            pending.map { "Stop \(ProcessStopModel.name($0.process))?" } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { stop in
            Button("Stop", role: .destructive) {
                _Concurrency.Task { await env.processStops.stop(stop.process.identity, in: sample?.inventory ?? stop.inventory) }
            }
        } message: { stop in
            Text(stop.detail)
        }
        .task {
            guard let sampler = env.processSampler else { return }
            env.listeningPorts?.refresh()
            for await next in sampler.samples(every: Self.interval) {
                sample = next
                loadTitles(next)
            }
        }
    }

    private var selectedIdentity: PIDIdentity? {
        selection.flatMap(identity(of:))
    }

    private func identity(of id: ProcessRow.ID) -> PIDIdentity? {
        rows.first { $0.id == id }?.identity
    }

    private func requestStop(_ id: ProcessRow.ID) {
        guard let identity = identity(of: id), let inventory = sample?.inventory,
              let process = inventory.processes.first(where: { $0.identity == identity })
        else { return }
        let model = env.processStops
        _Concurrency.Task {
            guard let plan = await model.prepare(identity, in: inventory) else { return }
            pending = PendingProcessStop(
                process: process, inventory: inventory,
                detail: ProcessStopModel.confirmation(plan, process: process, grace: PortStopper().grace)
            )
        }
    }

    private func loadTitles(_ sample: SampledInventory) {
        let store = TaskStore(env.db)
        for taskId in Set(sample.inventory.processes.compactMap(\.owner.taskId)) where taskTitles[taskId] == nil {
            if let title = try? store.get(taskId)?.title { taskTitles[taskId] = title }
        }
    }
}
