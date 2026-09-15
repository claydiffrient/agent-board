import AgentBoardCore
import AgentBoardRuntime
import SwiftUI

struct ApprovalsSidebar: View {
    let project: Project

    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @State private var approvals = Observed<[Approval]>([])
    @State private var tasks = Observed<[BoardTask]>([])
    @State private var sessions = Observed<[AgentSession]>([])
    @State private var reports = Observed<[Report]>([])
    @State private var messages = Observed<[MessageEntry]>([])
    @State private var now = Date.now
    @State private var denying: Approval?
    @State private var denyReason = ""
    @State private var errorMessage: String?

    private var taskTitles: [String: String] {
        Dictionary(uniqueKeysWithValues: tasks.value.map { ($0.id, $0.title) })
    }

    private var proposals: [BoardTask] {
        tasks.value.filter { $0.column == .proposed }
    }

    private var attention: [AttentionItem] {
        AttentionSelection.needingAttention(
            tasks: tasks.value,
            sessions: sessions.value,
            awake: SleepLedger.shared.reading(asOf: now),
            stallThreshold: TimeInterval(project.settings.caps.stallSeconds)
        )
    }

    private var reviews: [BoardTask] {
        BoardTask.pendingReview(in: tasks.value)
    }

    private var latestSessionByTask: [String: AgentSession] {
        var result: [String: AgentSession] = [:]
        for session in sessions.value {
            guard let taskId = session.taskId, result[taskId] == nil else { continue }
            result[taskId] = session
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section("Blocked") {
                    if attention.isEmpty {
                        Text("No worker is waiting on you.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(attention) { item in
                        attentionRow(item)
                    }
                }
                Section("Pending approvals") {
                    if approvals.value.isEmpty {
                        Text("Nothing waiting on you.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(approvals.value) { approval in
                        approvalRow(approval)
                    }
                }
                Section("Pending reviews") {
                    if reviews.isEmpty {
                        Text("Nothing waiting for review.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(reviews) { task in
                        ReviewRow(
                            task: task,
                            session: latestSessionByTask[task.id],
                            accept: { run { try await env.supervisor.accept(taskId: task.id) } },
                            reopen: { run { try await env.supervisor.reopen(taskId: task.id) } }
                        )
                    }
                }
                Section("Proposals") {
                    if proposals.isEmpty {
                        Text("No worker proposals.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(proposals) { task in
                        proposalRow(task)
                    }
                }
                Section("Messages") {
                    if messages.value.isEmpty {
                        Text("No messages with other projects.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(messages.value) { entry in
                        MessageRow(entry: entry, projectName: project.name)
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            footer
        }
        .task(id: project.id) {
            await approvals.run(ApprovalStore(env.db).observePending(projectId: project.id), in: env.db.reader)
        }
        .task(id: project.id) {
            await tasks.run(TaskStore(env.db).observe(projectId: project.id), in: env.db.reader)
        }
        .task(id: project.id) {
            await sessions.run(SessionStore(env.db).observe(projectId: project.id), in: env.db.reader)
        }
        .task(id: project.id) {
            await reports.run(ReportStore(env.db).observeUnconsumed(projectId: project.id), in: env.db.reader)
        }
        .task(id: project.id) {
            await messages.run(MessageStore(env.db).observeConversation(projectId: project.id), in: env.db.reader)
        }
        .task {
            while !_Concurrency.Task.isCancelled {
                now = .now
                do { try await _Concurrency.Task.sleep(for: .seconds(15)) } catch { break }
            }
        }
        .alert("Deny request?", isPresented: denyPresented, presenting: denying) { approval in
            TextField("Reason (optional)", text: $denyReason)
            Button("Deny", role: .destructive) {
                let reason = denyReason
                run { try await env.supervisor.deny(approvalId: approval.id, reason: reason) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { approval in
            Text("The orchestrator is told the decision, and the reason if you give one, through list_reports.\n\n\(describe(approval))")
        }
        .errorAlert($errorMessage)
    }

    @ViewBuilder
    private func attentionRow(_ item: AttentionItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.task.title)
                .fontWeight(.medium)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(item.kind.rawValue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                if let session = item.session {
                    Text(session.displayShortId)
                        .monospaced()
                }
                Text(Format.elapsed(from: item.since, to: now))
            }
            .font(.caption)
            .foregroundStyle(item.kind == .blocked ? .orange : .secondary)
            Text(detail(item))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            HStack {
                Button("Attach") {
                    if let session = item.session { openWindow(id: "terminal", value: session.sessionId) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(item.session == nil)
                Button("Stop") {
                    guard let session = item.session else { return }
                    run { try await env.supervisor.stop(sessionId: session.sessionId) }
                }
                .disabled(item.session == nil)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    /// D15: the row says enough to decide whether to attach; the prompt itself is read in the terminal.
    private func detail(_ item: AttentionItem) -> String {
        if let reason = item.reason, !reason.isEmpty { return reason }
        switch item.kind {
        case .blocked:
            return "Blocked with no reason recorded. Attach to see what it is asking."
        case .stalled:
            let tool = item.session?.lastTool.map { "since \($0)" } ?? "at all"
            return "No hook activity \(tool). It may be waiting on a child process's stdin, which fires no hook."
        }
    }

    private func approvalRow(_ approval: Approval) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(describe(approval))
                .fontWeight(.medium)
                .lineLimit(2)
            if let reason = approval.reason, !reason.isEmpty {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            HStack(spacing: 6) {
                Text(approval.kind.rawValue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Text("by \(requester(approval.requestedBy))")
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(Format.relative(approval.createdDate))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Button("Approve") { run { try await env.supervisor.approve(approvalId: approval.id) } }
                    .buttonStyle(.borderedProminent)
                Button("Deny…") {
                    denyReason = ""
                    denying = approval
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func proposalRow(_ task: BoardTask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.title)
                .fontWeight(.medium)
                .lineLimit(2)
            if let body = task.body, !body.isEmpty {
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack {
                Button("Promote") { run { try await env.supervisor.promote(taskId: task.id) } }
                    .buttonStyle(.borderedProminent)
                Button("Dismiss") { run { try await env.supervisor.discard(taskId: task.id) } }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                reports.value.isEmpty ? "No reports waiting" : "\(reports.value.count) reports waiting",
                systemImage: "tray.full"
            )
            .foregroundStyle(reports.value.isEmpty ? .secondary : .primary)
            Toggle("Autonomy (spawn without approval)", isOn: autonomy)
            Text("Off by default. While off, every orchestrator spawn waits for your approval.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var autonomy: Binding<Bool> {
        Binding(
            get: { project.settings.autonomyEnabled },
            set: { enabled in
                var settings = project.settings
                settings.autonomyEnabled = enabled
                do {
                    try ProjectStore(env.db).updateSettings(project.id, settings)
                } catch {
                    errorMessage = errorText(error)
                }
            }
        )
    }

    private var denyPresented: Binding<Bool> {
        Binding(
            get: { denying != nil },
            set: { if !$0 { denying = nil } }
        )
    }

    private func describe(_ approval: Approval) -> String {
        switch approval.kind {
        case .spawn:
            let title = approval.taskId.flatMap { taskTitles[$0] } ?? approval.taskId ?? "unknown task"
            return "Spawn a worker for \"\(title)\""
        case .integration:
            return "Integrate epic \(approval.epicId ?? "?")"
        case .push:
            return "Push \(branchOf(approval)) to the remote"
        case .pullRequest:
            return "Open a pull request from \(branchOf(approval))"
        }
    }

    private func branchOf(_ approval: Approval) -> String {
        (try? approval.publishRequest().branch) ?? "?"
    }

    private func requester(_ requestedBy: String) -> String {
        requestedBy.count > 12 ? String(requestedBy.prefix(8)) : requestedBy
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        _Concurrency.Task {
            do {
                try await operation()
            } catch {
                errorMessage = errorText(error)
            }
        }
    }
}

private struct ReviewRow: View {
    let task: BoardTask
    let session: AgentSession?
    let accept: () -> Void
    let reopen: () -> Void

    @Environment(AppEnvironment.self) private var env
    @State private var changes: DiffSummary?
    @State private var summary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.title)
                .fontWeight(.medium)
                .lineLimit(2)
            Label(session?.branch ?? "agentboard/\(task.id)", systemImage: "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let changes, !changes.isEmpty {
                changeSize(changes)
            }
            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack {
                Button("Accept", action: accept)
                    .buttonStyle(.borderedProminent)
                Button("Reopen", action: reopen)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .help(session?.worktreePath ?? "")
        .task(id: task.id) {
            summary = (try? ReportStore(env.db).latest(taskId: task.id)?.body)
                .flatMap { $0 }
                .map { WorkerReport.summaryText(body: $0) }
            changes = await env.supervisor.worktreeDiffSummary(taskId: task.id)
        }
    }

    private func changeSize(_ changes: DiffSummary) -> some View {
        HStack(spacing: 6) {
            Text(changes.filesChanged == 1 ? "1 file" : "\(changes.filesChanged) files")
            Text("+\(changes.insertions)")
                .foregroundStyle(.green)
            Text("\u{2212}\(changes.deletions)")
                .foregroundStyle(.red)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
