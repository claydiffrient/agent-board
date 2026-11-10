import XCTest
@testable import AgentBoardCore

/// SPEC §4: a worker's model and effort, each resolved through task, role, type row, project default.
final class WorkerModelTableTests: XCTestCase {
    func testEachLevelWinsOverEveryLevelBelowItForModelAndEffortIndependently() {
        let settings = ProjectSettings(
            defaultModel: "project-model", defaultEffort: .low,
            workerModels: WorkerModelTable(rows: [.docs: WorkerModelRow(model: "row-model", effort: .high)])
        )
        func resolve(
            task: (String?, Effort?) = (nil, nil), role: (String?, Effort?) = (nil, nil), type: TaskType? = .docs,
            in settings: ProjectSettings = settings
        ) -> WorkerModelChoice {
            .resolve(
                taskModel: task.0, taskEffort: task.1, roleModel: role.0, roleEffort: role.1, type: type,
                settings: settings
            )
        }

        XCTAssertEqual(
            resolve(task: ("task-model", .max), role: ("role-model", .xhigh)),
            WorkerModelChoice(model: "task-model", modelSource: .task, effort: .max, effortSource: .task)
        )
        XCTAssertEqual(
            resolve(role: ("role-model", .xhigh)),
            WorkerModelChoice(model: "role-model", modelSource: .role, effort: .xhigh, effortSource: .role)
        )
        XCTAssertEqual(
            resolve(),
            WorkerModelChoice(model: "row-model", modelSource: .typeTable, effort: .high, effortSource: .typeTable)
        )
        XCTAssertEqual(
            resolve(task: ("task-model", nil)),
            WorkerModelChoice(model: "task-model", modelSource: .task, effort: .high, effortSource: .typeTable),
            "a task's model alone leaves its effort to the next level that sets one"
        )
        let projectDefault = WorkerModelChoice(
            model: "project-model", modelSource: .projectDefault, effort: .low, effortSource: .projectDefault
        )
        XCTAssertEqual(resolve(type: .code), projectDefault, "a type with no row")
        XCTAssertEqual(resolve(type: nil), projectDefault, "an untyped task")
        XCTAssertEqual(
            resolve(in: ProjectSettings(workerModels: WorkerModelTable())), .claudeCodeDefault
        )
    }

    func testSettingsWithoutATableGetTheRecommendedOneUnlessTheyAlreadyChoseADefaultModel() {
        XCTAssertEqual(ProjectSettings.decode("{}").workerModels, .recommended)
        XCTAssertEqual(
            ProjectSettings.decode(#"{"defaultModel":"claude-opus-5"}"#).workerModels, WorkerModelTable(),
            "an explicit default model must not be overridden by type rows nobody chose"
        )

        var emptied = ProjectSettings.decode("{}")
        emptied.workerModels = WorkerModelTable()
        XCTAssertEqual(
            ProjectSettings.decode(emptied.encoded()).workerModels, WorkerModelTable(),
            "a table the human emptied stays empty after a save"
        )
    }
}
