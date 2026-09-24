import Observation

struct TaskDraft: Equatable {
    var body: String
    var acceptance: String
    var model: String?
}

/// Survives the inspector being dismissed so closing the tray never silently drops unsaved edits.
/// Keyed by task id, so a draft typed on one task never shows up, or submits, on another.
@Observable
final class TaskDraftCache {
    private var drafts: [String: TaskDraft] = [:]
    private var comments: [String: String] = [:]

    func draft(for taskId: String) -> TaskDraft? {
        drafts[taskId]
    }

    func retain(_ draft: TaskDraft, for taskId: String, ifDifferentFrom saved: TaskDraft) {
        drafts[taskId] = draft == saved ? nil : draft
    }

    func clear(_ taskId: String) {
        drafts[taskId] = nil
    }

    func comment(for taskId: String) -> String {
        comments[taskId] ?? ""
    }

    func setComment(_ text: String, for taskId: String) {
        comments[taskId] = text.isEmpty ? nil : text
    }
}
