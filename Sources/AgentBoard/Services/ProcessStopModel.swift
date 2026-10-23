import AgentBoardCore
import AgentBoardRuntime
import Darwin
import Foundation
import Observation
import os

/// The process view's Stop (SPEC §8.7, §10). Every call re-plans against a fresh process table
/// and registry, so a row drawn seconds ago is checked again before anything is signalled.
@Observable
@MainActor
final class ProcessStopModel {
    private(set) var stopping: Set<PIDIdentity> = []
    /// The last refusal or outcome, for the view's status line.
    private(set) var message: String?

    @ObservationIgnored private let db: AppDatabase
    @ObservationIgnored private let supervisor: any WorkerSupervising
    @ObservationIgnored private let hosts: @Sendable () async -> [pid_t: String]
    @ObservationIgnored private let isClaude: @Sendable (pid_t) -> Bool
    @ObservationIgnored private let stopper: PortStopper
    @ObservationIgnored private let logger = Logger(subsystem: "AgentBoard", category: "process-stop")

    init(
        db: AppDatabase,
        supervisor: any WorkerSupervising,
        hosts: @escaping @Sendable () async -> [pid_t: String] = ProcessStopModel.registryHosts,
        isClaude: @escaping @Sendable (pid_t) -> Bool = ProcessStopPlanner.isClaude,
        stopper: PortStopper = PortStopper()
    ) {
        self.db = db
        self.supervisor = supervisor
        self.hosts = hosts
        self.isClaude = isClaude
        self.stopper = stopper
    }

    func plan(_ row: PIDIdentity, in inventory: ProcessInventory) async throws -> ProcessStopPlan {
        let hosts = await hosts()
        return try ProcessStopPlanner.plan(
            row, inventory: inventory, table: ProcessTable.current(), hosts: hosts,
            isClaude: isClaude, board: getpid(), uid: getuid()
        )
    }

    /// Plans for a confirmation; a refusal lands in `message` and returns nil.
    func prepare(_ row: PIDIdentity, in inventory: ProcessInventory) async -> ProcessStopPlan? {
        message = nil
        do {
            return try await plan(row, in: inventory)
        } catch {
            message = Self.message(for: error)
            return nil
        }
    }

    func stop(_ row: PIDIdentity, in inventory: ProcessInventory) async {
        guard stopping.insert(row).inserted else { return }
        defer { stopping.remove(row) }
        message = nil
        guard let process = inventory.processes.first(where: { $0.identity == row }) else {
            message = Self.message(for: ProcessStopRefusal.notInInventory)
            return
        }
        do {
            switch try await plan(row, in: inventory) {
            case .session(let sessionId):
                try await supervisor.stop(sessionId: sessionId)
                log("Stopped \(Self.name(process)), its session's claude host, from the process view.", for: process.owner)
                message = "Stopped the session"
            case .tree(let tree):
                let report = await stopper.stop(tree)
                let text = Self.summary(process, report, grace: stopper.grace)
                log(text, for: process.owner)
                message = report.survivors.isEmpty ? "Stopped" : "\(report.survivors.count) still running after SIGKILL"
            }
        } catch {
            message = Self.message(for: error)
        }
    }

    /// Every task-owned stop goes on the task's progress, anything else project-owned to the
    /// project's report queue as a `decision`; the app's own helpers have no board home.
    private func log(_ text: String, for owner: ProcessOwner) {
        if let taskId = owner.taskId {
            _ = try? ProgressStore(db).append(taskId: taskId, sessionId: nil, kind: .note, text: text)
        } else if let projectId = owner.projectId {
            _ = try? ReportStore(db).insert(projectId: projectId, taskId: nil, sessionId: nil, kind: .decision, body: text)
        } else if owner.role == .coordinator {
            _ = try? ReportStore(db).insertForCoordinator(sessionId: nil, kind: .decision, body: text)
        } else {
            logger.notice("\(text, privacy: .public)")
        }
    }

    static func name(_ process: InventoryProcess) -> String {
        "\(process.command) (pid \(process.pid))"
    }

    static func summary(_ process: InventoryProcess, _ report: ProcessTreeStopReport, grace: Duration) -> String {
        let count = report.signalled.count
        var text = "Stopped \(name(process)) from the process view: SIGTERM to \(count == 1 ? "1 process" : "\(count) processes")"
        if report.escalated { text += ", then SIGKILL after \(grace.components.seconds)s" }
        if !report.survivors.isEmpty { text += "; \(report.survivors.count) still running" }
        return text + "."
    }

    /// What the confirmation names before anything is signalled.
    static func confirmation(_ plan: ProcessStopPlan, process: InventoryProcess, grace: Duration) -> String {
        switch plan {
        case .session:
            return "This is the session's claude host. Stopping it runs the session's Stop: claude stop, "
                + "its process tree reaped and its grant revoked."
        case .tree(let tree):
            let others = tree.members.count - 1
            let below = others == 0 ? "" : others == 1 ? " and 1 process under it" : " and \(others) processes under it"
            let group = tree.group.map { " Its process group \($0) is signalled too." } ?? ""
            return "Sends SIGTERM to \(name(process))\(below), then SIGKILL to anything still running after "
                + "\(grace.components.seconds)s.\(group)"
        }
    }

    static func message(for error: Error) -> String {
        guard let refusal = error as? ProcessStopRefusal else { return error.localizedDescription }
        switch refusal {
        case .agentBoard: return "Agent Board itself — refused"
        case .sessionHost(let pid): return "pid \(pid) is a claude session — refused; stop its session instead"
        case .consoleHost: return "Runs in its console — stop it there"
        case .notInInventory: return "No longer in the process list"
        case .identityChanged: return "It exited, or its pid now names another process"
        case .otherUser(let pid): return "pid \(pid) belongs to another user — refused"
        }
    }

    /// Every `claude` host the registry lists. A failed read lists none; the planner still refuses
    /// any `claude` executable, so that fails safe.
    nonisolated static let registryHosts: @Sendable () async -> [pid_t: String] = {
        guard let listed = try? await BackgroundSessionRuntime().listSessions() else { return [:] }
        return listed.reduce(into: [pid_t: String]()) { result, info in
            guard let pid = info.pid, pid > 0, let sessionId = info.sessionId else { return }
            result[pid_t(pid)] = sessionId
        }
    }
}
