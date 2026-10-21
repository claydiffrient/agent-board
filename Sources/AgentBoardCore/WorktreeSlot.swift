import Foundation
import GRDB

/// A pooled worktree at `<worktree root>/slot-<n>` that outlives its tasks, so a build directory
/// inside it stays warm (SPEC §3.1 step 2). Leased to one task from spawn until that task is
/// accepted or discarded; `taskId` is nil while the slot is free.
public struct WorktreeSlot: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "worktree_slot"

    public var projectId: String
    /// Numbered from 1.
    public var slot: Int
    /// Not a foreign key: a discarded task's row is deleted while its slot may still hold its
    /// uncommitted work, and only reconcile may hand that slot on.
    public var taskId: String?
    public var leasedAt: Int64?

    public enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case slot
        case taskId = "task_id"
        case leasedAt = "leased_at"
    }

    public init(projectId: String, slot: Int, taskId: String? = nil, leasedAt: Int64? = nil) {
        self.projectId = projectId
        self.slot = slot
        self.taskId = taskId
        self.leasedAt = leasedAt
    }

    public static func name(_ slot: Int) -> String { "slot-\(slot)" }

    /// The slot number when `path` is `<root>/slot-<n>`, nil for any other path.
    public static func index(ofPath path: String, root: String) -> Int? {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard name.hasPrefix("slot-"), let slot = Int(name.dropFirst("slot-".count)), slot > 0,
              name == Self.name(slot),
              resolved(url.deletingLastPathComponent()) == resolved(URL(fileURLWithPath: root))
        else { return nil }
        return slot
    }

    private static func resolved(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// What `Board.assign` may lease from: slots 1 through `count` under `root`, minus `unusable` —
/// a directory that is not a worktree of this repository, or one with uncommitted changes.
public struct WorktreeSlotPool: Sendable, Equatable {
    public var root: String
    public var count: Int
    public var unusable: Set<Int>

    public init(root: String, count: Int, unusable: Set<Int> = []) {
        self.root = root
        self.count = count
        self.unusable = unusable
    }

    public func path(_ slot: Int) -> String {
        URL(fileURLWithPath: root).appendingPathComponent(WorktreeSlot.name(slot)).path
    }
}

public struct WorktreeSlotStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    public func slots(projectId: String) throws -> [WorktreeSlot] {
        try db.reader.read { db in try Self.slots(db, projectId: projectId) }
    }

    public func lease(taskId: String) throws -> WorktreeSlot? {
        try db.reader.read { db in
            try WorktreeSlot.filter(Column("task_id") == taskId).fetchOne(db)
        }
    }

    /// Frees the slot only while `taskId` still holds it, so a late release cannot free a slot
    /// some other task has leased since.
    public func release(projectId: String, slot: Int, taskId: String) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE worktree_slot SET task_id = NULL, leased_at = NULL WHERE project_id = ? AND slot = ? AND task_id = ?",
                arguments: [projectId, slot, taskId]
            )
        }
    }

    /// A retired slot's row goes only while the slot is free.
    public func retire(projectId: String, slot: Int) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM worktree_slot WHERE project_id = ? AND slot = ? AND task_id IS NULL",
                arguments: [projectId, slot]
            )
        }
    }

    static func slots(_ db: Database, projectId: String) throws -> [WorktreeSlot] {
        try WorktreeSlot.filter(Column("project_id") == projectId).order(Column("slot")).fetchAll(db)
    }

    /// The task's slot if it already holds one, otherwise the lowest free, usable slot nobody is
    /// still running in, now leased to it. Nil when there is none.
    static func lease(
        _ db: Database, projectId: String, taskId: String, pool: WorktreeSlotPool, now: Int64 = .nowMillis
    ) throws -> Int? {
        if let held = try WorktreeSlot.filter(Column("task_id") == taskId).fetchOne(db) { return held.slot }
        guard pool.count > 0 else { return nil }
        let rows = Dictionary(uniqueKeysWithValues: try slots(db, projectId: projectId).map { ($0.slot, $0) })
        for slot in 1...pool.count where rows[slot]?.taskId == nil && !pool.unusable.contains(slot) {
            if try SessionStore.activeHolder(db, worktreePath: pool.path(slot)) != nil { continue }
            try WorktreeSlot(projectId: projectId, slot: slot, taskId: taskId, leasedAt: now).save(db)
            return slot
        }
        return nil
    }
}
