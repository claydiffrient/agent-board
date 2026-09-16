import AgentBoardCore
import AppKit
import SwiftUI

/// SPEC §9: the wind-down sheet for one project. Nothing here polls — the delivery rows and
/// sessions come from GRDB observations, and `WorkerSupervisor.shutdownProgress` republishes on
/// every metering tick, which is what moves a silent worker past its grace period while the sheet
/// is open.
struct ShutdownSheet: View {
    let project: Project
    let order: ShutdownOrder
    let console: OrchestratorConsole?

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var deliveries = Observed<[ShutdownDelivery]>([])
    @State private var sessions = Observed<[AgentSession]>([])
    @State private var tasks = Observed<[BoardTask]>([])
    @State private var errorMessage: String?

    private var rows: [ShutdownRow] {
        ShutdownSheetModel.rows(
            deliveries: deliveries.value,
            sessions: sessions.value,
            taskTitles: Dictionary(tasks.value.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first }),
            graceSeconds: project.settings.caps.shutdownGraceSeconds,
            awake: SleepLedger.shared.reading()
        )
    }

    private var counts: ShutdownCounts {
        ShutdownSheetModel.counts(rows: rows, reported: env.supervisor.shutdownProgress[project.id])
    }

    var body: some View {
        let progress = counts
        return ShutdownSheetBody(
            headline: progress.headline,
            detail: headerDetail(progress),
            isComplete: progress.isComplete,
            rows: rows,
            footerNote: "Spawning is refused while this order stands.",
            attach: { openWindow(id: "terminal", value: $0) },
            stop: { sessionId in run { try await env.supervisor.stop(sessionId: sessionId) } }
        ) {
            Button("Cancel Shutdown") { cancel() }
                .help("Lets the orchestrator spawn again. Workers that already stopped stay stopped.")
            if progress.isComplete {
                Button("Quit Agent Board") { quit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .task(id: order.id) {
            await deliveries.run(ShutdownDeliveryStore(env.db).observeAll(orderId: order.id), in: env.db.reader)
        }
        .task(id: project.id) {
            await sessions.run(SessionStore(env.db).observe(projectId: project.id), in: env.db.reader)
        }
        .task(id: project.id) {
            await tasks.run(TaskStore(env.db).observe(projectId: project.id), in: env.db.reader)
        }
        .errorAlert($errorMessage)
    }

    private func headerDetail(_ counts: ShutdownCounts) -> String {
        if counts.total == 0 {
            return "No worker was running when the order was raised. Spawning is refused until you cancel or quit."
        }
        if counts.isComplete {
            return "Every worker committed its worktree and stopped. Their unfinished tasks are back in ready with resume notes."
        }
        var lines = ["Each worker commits what it has, leaves its task resumable, and acknowledges. Nothing is killed on its own."]
        if counts.waitingOnHuman > 0 {
            lines.append("\(counts.waitingOnHuman) is stopped on a permission prompt and cannot be reached until you answer it — attach to clear it.")
        }
        if counts.notResponding > 0 {
            lines.append("\(counts.notResponding) is past its grace period. Stop it to kill the process; its task still goes back to ready.")
        }
        return lines.joined(separator: " ")
    }

    /// Cancelling lifts the standing refusal; it does not restart anything. A worker that already
    /// acknowledged is gone, and its task sits in `ready` with its resume note — nothing is lost,
    /// but nothing comes back by itself either.
    private func cancel() {
        run {
            _ = try await env.supervisor.cancelShutdown(projectId: project.id, by: "human")
            await MainActor.run { dismiss() }
        }
    }

    /// The plain Stop button already ends the console; quitting does the same before terminating so
    /// the orchestrator session is not left running behind a closed app.
    private func quit() {
        console?.stop()
        NSApplication.shared.terminate(nil)
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

/// The chrome both wind-down sheets share: the progress header, the per-session rows and their
/// state rules, and the footer. The wording itself is computed in `ShutdownSheetModel` and
/// `GlobalShutdown` and handed in, so the two sheets cannot drift apart.
struct ShutdownSheetBody<Actions: View>: View {
    let headline: String
    let detail: String
    let isComplete: Bool
    let rows: [ShutdownRow]
    let footerNote: String
    let attach: (String) -> Void
    let stop: (String) -> Void
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            List(rows) { row in
                ShutdownRowView(
                    row: row,
                    attach: { attach(row.sessionId) },
                    stop: { stop(row.sessionId) }
                )
            }
            .listStyle(.inset)
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(headline)
                    .font(.title3.weight(.semibold))
            }
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Text(footerNote)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            actions()
        }
        .padding(16)
    }
}

private struct ShutdownRowView: View {
    let row: ShutdownRow
    let attach: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.taskTitle ?? "No task")
                    .fontWeight(.medium)
                    .lineLimit(2)
                if let projectName = row.projectName {
                    Text(projectName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            HStack(spacing: 6) {
                Text(row.state.label)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Text(row.displayShortId)
                    .monospaced()
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    Text(Format.elapsed(from: row.since, to: context.date))
                }
            }
            .font(.caption)
            .foregroundStyle(stateColor)
            Text(row.note ?? row.state.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if row.state == .waitingOnHuman || row.state == .notResponding {
                HStack {
                    if row.state == .waitingOnHuman {
                        Button("Attach", action: attach)
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Stop", action: stop)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var stateColor: SwiftUI.Color {
        switch row.state {
        case .acknowledged, .ended: .secondary
        case .closing, .ordered: .blue
        case .waitingOnHuman: .orange
        case .notResponding: .red
        }
    }
}

#Preview("Shutdown in progress") {
    let preview = PreviewData.make()
    ShutdownSheet(
        project: preview.project,
        order: ShutdownOrder(
            id: "order-1", projectId: preview.project.id, requestedBy: "human",
            reason: "End of day", requestedAt: .nowMillis - 90_000
        ),
        console: nil
    )
    .environment(preview.environment)
}
