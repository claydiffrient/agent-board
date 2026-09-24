import AgentBoardCore
import SwiftUI

enum CommentComposer {
    static func canSubmit(_ draft: String) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Writes the draft as the human's comment; a blank draft writes nothing and returns nil.
    @discardableResult
    static func submit(_ draft: String, to task: BoardTask, db: AppDatabase) throws -> TaskComment? {
        guard canSubmit(draft) else { return nil }
        return try Board(db).addComment(projectId: task.projectId, taskId: task.id, author: .human, body: draft)
    }

    /// Submits the draft held for `task` itself, and clears it once written.
    @discardableResult
    static func submit(from drafts: TaskDraftCache, to task: BoardTask, db: AppDatabase) throws -> TaskComment? {
        guard let comment = try submit(drafts.comment(for: task.id), to: task, db: db) else { return nil }
        drafts.setComment("", for: task.id)
        return comment
    }
}

/// The inspector's comment thread and composer. The human's comments sit on an accent tint; agents'
/// sit on a neutral grey behind an icon for their kind (SPEC §10).
struct TaskCommentsSection: View {
    let task: BoardTask
    let drafts: TaskDraftCache

    @Environment(AppEnvironment.self) private var env
    @State private var thread = Observed(CommentThread())
    @State private var errorMessage: String?

    private var draft: Binding<String> {
        let taskId = task.id
        return Binding(get: { drafts.comment(for: taskId) }, set: { drafts.setComment($0, for: taskId) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Comments (\(thread.value.comments.count))")
                .font(.subheadline.weight(.semibold))
            if thread.value.comments.isEmpty {
                Text("No comments yet.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            ForEach(thread.value.comments) { comment in
                CommentRow(comment: comment, author: thread.value.authorLabel(comment))
            }
            composer
        }
        .task(id: task.id) {
            await thread.run(CommentStore(env.db).observeThread(taskId: task.id), in: env.db.reader)
        }
        .errorAlert($errorMessage)
    }

    private var composer: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TextEditor(text: draft)
                .font(.body)
                .frame(minHeight: 56)
                .overlay(alignment: .topLeading) {
                    if draft.wrappedValue.isEmpty {
                        Text("Add a comment")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.3))
                )
            Button("Add Comment", action: submit)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!CommentComposer.canSubmit(draft.wrappedValue))
                .help("Add this comment (⌘↩)")
        }
    }

    private func submit() {
        do {
            try CommentComposer.submit(from: drafts, to: task, db: env.db)
        } catch {
            errorMessage = errorText(error)
        }
    }
}

private struct CommentRow: View {
    let comment: TaskComment
    let author: String

    private var isHuman: Bool { comment.authorKind == .human }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: comment.authorKind.symbolName)
                    .foregroundStyle(isHuman ? Color.accentColor : .secondary)
                Text(author)
                    .fontWeight(.semibold)
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(Format.relative(comment.createdDate))
                        .foregroundStyle(.tertiary)
                }
                .help(comment.createdDate.formatted(date: .abbreviated, time: .standard))
            }
            .font(.caption)
            Text(comment.body)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHuman ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.1))
        )
    }
}

extension CommentAuthorKind {
    var symbolName: String {
        switch self {
        case .human: "person.crop.circle"
        case .orchestrator: "terminal"
        case .worker: "cpu"
        case .reviewer: "checkmark.seal"
        }
    }
}
