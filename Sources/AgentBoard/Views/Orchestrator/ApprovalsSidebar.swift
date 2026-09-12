import AgentBoardCore
import SwiftUI

struct ApprovalsSidebar: View {
    let project: Project

    @Environment(AppEnvironment.self) private var env
    @State private var approvals = Observed<[Approval]>([])
    @State private var tasks = Observed<[BoardTask]>([])
    @State private var reports = Observed<[Report]>([])
    @State private var denying: Approval?
    @State private var denyReason = ""
    @State private var errorMessage: String?

    private var taskTitles: [String: String] {
        Dictionary(uniqueKeysWithValues: tasks.value.map { ($0.id, $0.title) })
    }

    private var proposals: [BoardTask] {
        tasks.value.filter { $0.column == .proposed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section("Pending approvals") {
                    if approvals.value.isEmpty {
                        Text("Nothing waiting on you.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(approvals.value) { approval in
                        approvalRow(approval)
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
            await reports.run(ReportStore(env.db).observeUnconsumed(projectId: project.id), in: env.db.reader)
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

    private func approvalRow(_ approval: Approval) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(describe(approval))
                .fontWeight(.medium)
                .lineLimit(2)
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
        }
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
