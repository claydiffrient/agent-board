import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

final class WorkerNoteToolTests: XCTestCase {
    private var f: BridgeFixture!
    private var worker: TokenIdentity!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        let task = try f.task("t", column: .running)
        try f.session("s1", taskId: task.id)
        worker = f.workerIdentity(sessionId: "s1", taskId: task.id)
    }

    private func call(_ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> ToolResult {
        try await f.call(name, arguments, as: worker)
    }

    private func callJSON(_ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await f.callJSON(name, arguments, as: worker)
    }

    // MARK: Tool list

    func testWorkerSeesTheFiveNoteToolsButNotTheOrchestratorOnlyTwo() async {
        let names = await f.scoped.tools(for: worker).map(\.name)
        for tool in ["search_notes", "read_note", "append_section", "replace_section", "create_note"] {
            XCTAssertTrue(names.contains(tool), "worker scope is missing \(tool)")
        }
        XCTAssertFalse(names.contains("attach_note"))
        XCTAssertFalse(names.contains("pin_note"))
    }

    func testEveryWorkerSchemaForbidsAdditionalProperties() async {
        for tool in await f.worker.tools(for: worker) {
            XCTAssertEqual(tool.inputSchema["additionalProperties"], .bool(false), tool.name)
        }
    }

    func testWorkerCallingAttachOrPinGetsToolNotFound() async throws {
        let note = try f.note("Build gotchas")
        let task = try XCTUnwrap(worker.taskId)
        await XCTAssertToolError(
            try await call("attach_note", ["note_id": .string(note.id), "task_id": .string(task)]),
            containing: "Unknown tool"
        )
        await XCTAssertToolError(
            try await call("pin_note", ["note_id": .string(note.id), "pinned": .bool(true)]),
            containing: "Unknown tool"
        )
        XCTAssertEqual(try f.notes.links(noteId: note.id).count, 0)
        XCTAssertEqual(try f.notes.get(note.id)?.pinned, false)
    }

    // MARK: create_note and read_note

    func testCreateNoteStartsUnpinnedAtVersionOneAndReadsBackItsSections() async throws {
        let created = try await callJSON("create_note", [
            "title": .string("Bazel traps"),
            "sections": .array([
                .object(["heading": .string("Gazelle"), "body": .string("Run it after adding files.")]),
                .object(["heading": .string("Caching"), "body": .string("Remote cache needs creds.")]),
            ]),
        ])
        let id = try XCTUnwrap(created["id"]?.stringValue)
        XCTAssertEqual(created["pinned"], .bool(false))
        XCTAssertEqual(created["version"], .number(1))

        let note = try await callJSON("read_note", ["id": .string(id)])
        XCTAssertEqual(note["title"], .string("Bazel traps"))
        XCTAssertEqual(note["version"], .number(1))
        let sections = try XCTUnwrap(note["sections"]?.arrayValue)
        XCTAssertEqual(sections.map { $0["heading"] }, [.string("Gazelle"), .string("Caching")])
        XCTAssertEqual(sections.first?["body"], .string("Run it after adding files."))
    }

    func testCreateNoteWithoutSectionsIsAllowed() async throws {
        let created = try await callJSON("create_note", ["title": .string("Empty")])
        let id = try XCTUnwrap(created["id"]?.stringValue)
        XCTAssertEqual(try f.notes.read(id)?.1.count, 0)
    }

    func testCreateNoteRejectsMalformedSections() async {
        await XCTAssertToolError(
            try await call("create_note", ["title": .string("x"), "sections": .array([.object(["body": .string("no heading")])])]),
            containing: "heading"
        )
        await XCTAssertToolError(
            try await call("create_note", ["title": .string("x"), "sections": .string("not an array")]),
            containing: "must be an array"
        )
    }

    func testReadNoteOnAMissingNoteIsRefused() async {
        await XCTAssertToolError(try await call("read_note", ["id": .string("nope")]), containing: "not in this project")
    }

    // MARK: search_notes

    func testSearchNotesMatchesTitleAndSectionBodyWithinTheProject() async throws {
        let match = try f.note("Deploy runbook", sections: [(heading: "Steps", body: "Flip the canary flag first.")])
        try f.note("Unrelated", sections: [(heading: "Steps", body: "Nothing to see.")])

        let byBody = try await callJSON("search_notes", ["query": .string("canary")]).arrayValue ?? []
        XCTAssertEqual(byBody.map { $0["id"] }, [.string(match.id)])
        XCTAssertEqual(byBody.first?["title"], .string("Deploy runbook"))
        XCTAssertEqual(byBody.first?["version"], .number(1))

        let byTitle = try await callJSON("search_notes", ["query": .string("runbook")]).arrayValue ?? []
        XCTAssertEqual(byTitle.map { $0["id"] }, [.string(match.id)])

        let miss = try await callJSON("search_notes", ["query": .string("zebra")]).arrayValue ?? []
        XCTAssertEqual(miss.count, 0)
    }

    func testSearchNotesDoesNotReachAnotherProject() async throws {
        let other = try f.otherProject()
        try f.note("Deploy runbook", sections: [(heading: "Steps", body: "Flip the canary flag first.")], in: other.id)

        let results = try await callJSON("search_notes", ["query": .string("canary")]).arrayValue ?? []
        XCTAssertEqual(results.count, 0, "a worker must not see another project's notes")
    }

    // MARK: append_section / replace_section

    func testAppendSectionKeepsExistingTextAndBumpsTheVersion() async throws {
        let note = try f.note("Constraints", sections: [(heading: "DB", body: "One writer.")])

        let first = try await callJSON("append_section", [
            "note_id": .string(note.id), "heading": .string("DB"), "body": .string("WAL mode is on."),
        ])
        XCTAssertEqual(first["version"], .number(2))

        let read = try await callJSON("read_note", ["id": .string(note.id)])
        let sections = try XCTUnwrap(read["sections"]?.arrayValue)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?["body"], .string("One writer.\n\nWAL mode is on."))
    }

    func testAppendSectionWithANewHeadingAddsItAtTheEnd() async throws {
        let note = try f.note("Constraints", sections: [(heading: "DB", body: "One writer.")])
        _ = try await call("append_section", [
            "note_id": .string(note.id), "heading": .string("HTTP"), "body": .string("Loopback only."),
        ])

        let sections = try XCTUnwrap(f.notes.read(note.id)?.1)
        XCTAssertEqual(sections.map(\.heading), ["DB", "HTTP"])
        XCTAssertEqual(sections.last?.body, "Loopback only.")
    }

    func testReplaceSectionOverwritesTheBody() async throws {
        let note = try f.note("Constraints", sections: [(heading: "DB", body: "One writer.")])
        let result = try await callJSON("replace_section", [
            "note_id": .string(note.id), "heading": .string("DB"), "body": .string("Two writers now."), "if_version": .number(1),
        ])
        XCTAssertEqual(result["version"], .number(2))
        XCTAssertEqual(try f.notes.read(note.id)?.1.first?.body, "Two writers now.")
    }

    func testMatchingIfVersionIsAcceptedAndAStaleOneIsNot() async throws {
        let note = try f.note("Constraints", sections: [(heading: "DB", body: "One writer.")])
        _ = try await call("append_section", [
            "note_id": .string(note.id), "heading": .string("DB"), "body": .string("From worker A."), "if_version": .number(1),
        ])
        XCTAssertEqual(try f.notes.get(note.id)?.version, 2)

        await XCTAssertToolError(
            try await call("append_section", [
                "note_id": .string(note.id), "heading": .string("DB"), "body": .string("From worker B."), "if_version": .number(1),
            ]),
            containing: "now at version 2"
        )
    }

    func testIfVersionConflictNamesTheCurrentVersionAndWritesNothing() async throws {
        let note = try f.note("Constraints", sections: [(heading: "DB", body: "One writer.")])
        try f.notes.appendSection(noteId: note.id, heading: "DB", body: "Another agent got here first.")

        for tool in ["append_section", "replace_section"] {
            do {
                _ = try await call(tool, [
                    "note_id": .string(note.id), "heading": .string("DB"), "body": .string("Stale write."), "if_version": .number(1),
                ])
                XCTFail("\(tool) accepted a stale if_version")
            } catch let error as ToolError {
                XCTAssertTrue(error.message.contains("version 2"), "\(tool): \(error.message)")
                XCTAssertTrue(error.message.contains("read_note"), "\(tool) must tell the worker how to retry: \(error.message)")
                XCTAssertTrue(error.message.contains(note.id), "\(tool): \(error.message)")
            }
        }

        let (current, sections) = try XCTUnwrap(f.notes.read(note.id))
        XCTAssertEqual(current.version, 2, "a refused write must not bump the version")
        XCTAssertEqual(sections.first?.body, "One writer.\n\nAnother agent got here first.")
    }

    func testOmittingIfVersionWritesBlind() async throws {
        let note = try f.note("Constraints", sections: [(heading: "DB", body: "One writer.")])
        try f.notes.appendSection(noteId: note.id, heading: "DB", body: "Someone else.")

        let result = try await callJSON("append_section", [
            "note_id": .string(note.id), "heading": .string("DB"), "body": .string("Me too."),
        ])
        XCTAssertEqual(result["version"], .number(3))
    }

    func testWritesToAnotherProjectsNoteAreRefused() async throws {
        let other = try f.otherProject()
        let foreign = try f.note("Theirs", sections: [(heading: "DB", body: "Hands off.")], in: other.id)

        for tool in ["append_section", "replace_section"] {
            await XCTAssertToolError(
                try await call(tool, [
                    "note_id": .string(foreign.id), "heading": .string("DB"), "body": .string("Mine now."),
                ]),
                containing: "not in this project"
            )
        }
        await XCTAssertToolError(try await call("read_note", ["id": .string(foreign.id)]), containing: "not in this project")

        XCTAssertEqual(try f.notes.read(foreign.id)?.1.first?.body, "Hands off.")
        XCTAssertEqual(try f.notes.get(foreign.id)?.version, 1)
    }

    func testCreateNoteLandsInTheTokensProject() async throws {
        let other = try f.otherProject()
        let created = try await callJSON("create_note", ["title": .string("Mine")])
        let id = try XCTUnwrap(created["id"]?.stringValue)

        XCTAssertEqual(try f.notes.get(id)?.projectId, f.project.id)
        XCTAssertEqual(try f.notes.list(projectId: other.id).count, 0)
    }
}
