import Observation

struct TaskDraft: Equatable {
    var body: String
    var acceptance: String
    var model: String?
}

/// Survives the inspector being dismissed so closing the tray never silently drops unsaved edits.
@Observable
final class TaskDraftCache {
    private var drafts: [String: TaskDraft] = [:]

    func draft(for taskId: String) -> TaskDraft? {
        drafts[taskId]
    }

    func retain(_ draft: TaskDraft, for taskId: String, ifDifferentFrom saved: TaskDraft) {
        drafts[taskId] = draft == saved ? nil : draft
    }

    func clear(_ taskId: String) {
        drafts[taskId] = nil
    }
}
