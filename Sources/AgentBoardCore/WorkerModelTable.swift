import Foundation

public struct WorkerModelRow: Codable, Sendable, Equatable {
    public var model: String?
    public var effort: Effort?

    public init(model: String? = nil, effort: Effort? = nil) {
        self.model = model
        self.effort = effort
    }

    public var isEmpty: Bool { model == nil && effort == nil }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try? c.decodeIfPresent(Effort.self, forKey: .effort)
    }
}

/// The model and effort a task of each type runs on when it sets neither (SPEC §4). A type with no
/// row, and an untyped task, fall through to the project's defaults.
public struct WorkerModelTable: Codable, Sendable, Equatable {
    public var rows: [TaskType: WorkerModelRow]

    public init(rows: [TaskType: WorkerModelRow] = [:]) {
        self.rows = rows.filter { !$0.value.isEmpty }
    }

    /// From "Which Claude model should you build with?" (claude.dev, read 2026-11-10).
    public static let recommended = WorkerModelTable(rows: [
        .code: WorkerModelRow(model: "claude-opus-5-5", effort: .medium),
        .tests: WorkerModelRow(model: "claude-sonnet-5-5", effort: .medium),
        .docs: WorkerModelRow(model: "claude-sonnet-5-5", effort: .medium),
        .review: WorkerModelRow(model: "claude-sonnet-5-5", effort: .medium),
        .plan: WorkerModelRow(model: "claude-opus-5-5", effort: .high),
    ])

    public func row(for type: TaskType?) -> WorkerModelRow? {
        type.flatMap { rows[$0] }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A type this build doesn't know drops its row rather than failing every setting.
        let raw = try c.decodeIfPresent([String: WorkerModelRow].self, forKey: .rows) ?? [:]
        self.init(rows: Dictionary(uniqueKeysWithValues: raw.compactMap { key, row in
            TaskType(rawValue: key).map { ($0, row) }
        }))
    }
}

/// Which level of SPEC §4's resolution order supplied a worker's model or effort.
public enum WorkerModelSource: String, Sendable, Equatable {
    case task
    case role
    case typeTable
    case projectDefault
    case claudeCode

    public var label: String {
        switch self {
        case .task: return "the task"
        case .role: return "the agent or role"
        case .typeTable: return "the type table"
        case .projectDefault: return "the project default"
        case .claudeCode: return "Claude Code's default"
        }
    }
}

/// The `--model` and `--effort` one spawn passes, each resolved on its own (SPEC §4): the task, the
/// rostered agent or role, the type table's row, the project default, then Claude Code's default.
public struct WorkerModelChoice: Sendable, Equatable {
    public var model: String?
    public var modelSource: WorkerModelSource
    public var effort: Effort?
    public var effortSource: WorkerModelSource

    public init(
        model: String?, modelSource: WorkerModelSource, effort: Effort?, effortSource: WorkerModelSource
    ) {
        self.model = model
        self.modelSource = modelSource
        self.effort = effort
        self.effortSource = effortSource
    }

    public static let claudeCodeDefault = WorkerModelChoice(
        model: nil, modelSource: .claudeCode, effort: nil, effortSource: .claudeCode
    )

    public static func resolve(
        taskModel: String?,
        taskEffort: Effort?,
        roleModel: String? = nil,
        roleEffort: Effort? = nil,
        type: TaskType?,
        settings: ProjectSettings
    ) -> WorkerModelChoice {
        let row = settings.workerModels.row(for: type)
        let model = first([
            (taskModel, .task), (roleModel, .role), (row?.model, .typeTable), (settings.defaultModel, .projectDefault),
        ])
        let effort = first([
            (taskEffort, .task), (roleEffort, .role), (row?.effort, .typeTable), (settings.defaultEffort, .projectDefault),
        ])
        return WorkerModelChoice(model: model.value, modelSource: model.source, effort: effort.value, effortSource: effort.source)
    }

    private static func first<T>(_ levels: [(T?, WorkerModelSource)]) -> (value: T?, source: WorkerModelSource) {
        for (value, source) in levels {
            if let value { return (value, source) }
        }
        return (nil, .claudeCode)
    }

    /// One sentence for `spawn_worker`'s answer, naming each value and the level it came from.
    public var summary: String {
        let model = self.model.map { "`\($0)`" } ?? "Claude Code's default model"
        let effort = self.effort.map { "`\($0.rawValue)` effort" } ?? "Claude Code's default effort"
        return "It runs on \(model) (from \(modelSource.label)) at \(effort) (from \(effortSource.label))."
    }
}
