import AgentBoardCore
import Foundation

/// One button in an Inbox row's Act zone: labeled with what it does, and confirmed against its concrete
/// target before it runs (SPEC §10, Inbox).
@MainActor
struct InboxAction: Identifiable {
    var id: String
    var label: String
    var confirmation: String
    var confirmButton: String
    var detail: String?
    var needsNote = false
    var destructive = false
    var run: () async throws -> Void

    static func offered(
        for item: InboxItem, context: InboxRowContext, note: String,
        supervisor: any WorkerSupervising, db: AppDatabase
    ) -> [InboxAction] {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        switch item.kind {
        case .approval:
            guard let approval = context.approval else { return [] }
            return [InboxAction(
                id: "approve", label: approveLabel(approval, task: context.task),
                confirmation: "\(describe(approval, task: context.task))?", confirmButton: "Approve",
                detail: approval.reason,
                run: { try await supervisor.approve(approvalId: approval.id) }
            )]
        case .blockedTask:
            guard let session = context.session else { return [] }
            return [InboxAction(
                id: "stop", label: "Stop the worker…",
                confirmation: "Stop \(session.displayShortId) on \"\(item.title)\"?", confirmButton: "Stop",
                detail: "The session ends; the task and its worktree stay.", destructive: true,
                run: { try await supervisor.stop(sessionId: session.sessionId) }
            )]
        case .humanReview, .reviewerStopped:
            let branch = context.session?.branch ?? "agentboard/\(item.subjectId)"
            var actions = [
                InboxAction(
                    id: "accept", label: "Accept into done — lands \(branch)…",
                    confirmation: "Accept \"\(item.title)\" into done and land \(branch)?", confirmButton: "Accept",
                    detail: "The task moves to done, its sessions stop, and its branch lands on its base.",
                    run: { try await supervisor.accept(taskId: item.subjectId) }
                ),
                InboxAction(
                    id: "reopen", label: "Reopen with my note…",
                    confirmation: "Reopen \"\(item.title)\" with your note?", confirmButton: "Reopen",
                    detail: "The task goes back to ready, and your note is recorded as a reopen ruling the next "
                        + "worker reads.\n\n\(note)",
                    needsNote: true,
                    run: { try await supervisor.reopen(taskId: item.subjectId, ruling: note) }
                ),
            ]
            if item.kind == .reviewerStopped {
                actions.append(InboxAction(
                    id: "rerun", label: "Re-run review — starts a new reviewer…",
                    confirmation: "Stop the reviewer on \"\(item.title)\" and start a fresh one?", confirmButton: "Re-run",
                    run: { try await supervisor.rerunReview(taskId: item.subjectId) }
                ))
            }
            return actions
        case .proposal:
            return [
                InboxAction(
                    id: "promote", label: "Promote onto the board…",
                    confirmation: "Promote \"\(item.title)\" onto the board?", confirmButton: "Promote",
                    run: { try await supervisor.promote(taskId: item.subjectId) }
                ),
                InboxAction(
                    id: "dismiss", label: "Dismiss — deletes the proposal…",
                    confirmation: "Delete the proposal \"\(item.title)\"?", confirmButton: "Delete", destructive: true,
                    run: { try await supervisor.discard(taskId: item.subjectId) }
                ),
            ]
        case .prDecision:
            guard let id = context.prItem?.id else { return [] }
            let number = context.watch.map { "#\($0.number)" } ?? "the pull request"
            return [InboxAction(
                id: "dismiss-item", label: "Dismiss the item with my note…",
                confirmation: "Dismiss this item on \(number)?", confirmButton: "Dismiss",
                detail: "No fix and no reply; no later check grades it. Your note is the reason.\n\n\(note)",
                needsNote: true, destructive: true,
                run: { try await supervisor.dismissPRItem(itemId: id, reason: note) }
            )]
        case .parkedWatch:
            guard let watch = context.watch else { return [] }
            let watches = PRWatchStore(db)
            return [
                InboxAction(
                    id: "resume", label: "Resume — follow-through may push fix rounds…",
                    confirmation: "Resume follow-through on #\(watch.number)?", confirmButton: "Resume",
                    detail: "Follow-through starts again with a fresh round cap and may push fix rounds to "
                        + "\(watch.headRef) and reply on GitHub.",
                    run: { _ = try watches.resume(watchId: watch.id) }
                ),
                InboxAction(
                    id: "stop-watching", label: "Stop watching #\(watch.number)…",
                    confirmation: "Stop watching #\(watch.number)?", confirmButton: "Stop watching",
                    detail: "Its open items are dismissed and it moves to Stopped until you choose Watch again.",
                    destructive: true,
                    run: { try watches.stopWatching(watchId: watch.id) }
                ),
            ]
        }
    }

    static func describe(_ approval: Approval, task: BoardTask?) -> String {
        switch approval.kind {
        case .spawn: "Spawn a worker for \"\(task?.title ?? approval.taskId ?? "unknown task")\""
        case .integration: "Integrate epic \(approval.epicId ?? "?")"
        case .push: "Push \(branch(approval)) to origin"
        case .pullRequest: "Open a pull request from \(branch(approval))"
        case .prItemDismissal: "Dismiss a pull request item"
        case .prWatchResume:
            (try? PRWatchResumeRequest.decode(approval.payload)).map { "Resume pull request #\($0.number)" }
                ?? "Resume a parked pull request"
        case .prWatchAdopt:
            (try? PRWatchAdoptionRequest.decode(approval.payload)).map { "Watch pull request #\($0.number)" }
                ?? "Watch a pull request taken over by hand"
        }
    }

    static func approveLabel(_ approval: Approval, task: BoardTask?) -> String {
        approval.kind == .prWatchResume
            ? "Approve — follow-through may push fix rounds…"
            : "Approve and \(describe(approval, task: task).lowercasedFirst)…"
    }

    private static func branch(_ approval: Approval) -> String {
        guard let request = try? approval.publishRequest() else { return "?" }
        return request.shortHeadOid.map { "\(request.head) at \($0)" } ?? request.head
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
