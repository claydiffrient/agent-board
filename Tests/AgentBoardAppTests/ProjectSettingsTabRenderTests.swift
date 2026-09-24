import AgentBoardCore
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// Mounts each settings tab offscreen and asserts on what that tab's controls hold.
///
/// Readable here: a text field's `stringValue` and `placeholderString`, a text view's string, font
/// and substitution flags, a pop-up's selected title, a switch's state, and every control's frame.
/// Not readable: any `Text` — labels, section headers and help text — so their wording, placement
/// and wrapping were checked only by looking at captures, never by this suite.
@MainActor
final class ProjectSettingsTabRenderTests: XCTestCase {
    private static let guidance = "Sonnet 5 for docs and tests, Opus 5 for features."

    private struct Mounted {
        let window: NSWindow
        let host: NSView

        func settle(turns: Int = 40) {
            for _ in 0..<turns {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                window.layoutIfNeeded()
                window.displayIfNeeded()
            }
        }

        func collect<V: NSView>(_ type: V.Type) -> [V] {
            var found: [V] = []
            func walk(_ view: NSView) {
                if let match = view as? V { found.append(match) }
                view.subviews.forEach(walk)
            }
            walk(host)
            return found
        }

        var fields: [NSTextField] { collect(NSTextField.self).filter { $0.isEditable } }

        func frame(of view: NSView) -> NSRect { view.convert(view.bounds, to: host) }
    }

    private func mount(
        tab: ProjectSettingsTab,
        rosterAgents: Int = 0,
        configure: (inout ProjectSettings) -> Void = { _ in },
        seed: (AppDatabase, String) throws -> Void = { _, _ in }
    ) throws -> Mounted {
        let db = try AppDatabase.inMemory()
        let projects = ProjectStore(db)
        var project = try projects.register(
            name: "Demo", repoPath: "/tmp/demo-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/demo-worktrees", memoryDir: nil
        )
        var settings = project.settings
        configure(&settings)
        try projects.updateSettings(project.id, settings)
        try seed(db, project.id)
        project = try XCTUnwrap(projects.get(project.id))
        for n in 0..<rosterAgents {
            try RosterStore(db).create(name: "Agent \(n)", role: "frontend", systemPrompt: "p")
        }

        let host = NSHostingView(
            rootView: ProjectSettingsSheet(project: project, workspaces: [], initialTab: tab, onDeleted: {})
                .environment(AppEnvironment(db: db, supervisor: RenderStubSupervisor(progress: [:])))
        )
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 780, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderBack(nil)
        let mounted = Mounted(window: window, host: host)
        mounted.settle()
        return mounted
    }

    func testGeneralHoldsTheRepositoryFieldsWorkspaceAndArchive() throws {
        let mounted = try mount(tab: .general) { $0.archivePolicy = .afterDays(21) }

        XCTAssertEqual(mounted.fields.map(\.stringValue), ["main", "/tmp/demo-worktrees", "21"])
        XCTAssertEqual(
            mounted.collect(NSPopUpButton.self).map(\.title),
            ["None", ArchivePolicyMode.afterDays.title]
        )
        XCTAssertTrue(mounted.collect(NSTextView.self).isEmpty)
    }

    /// The guidance editor used to sit in a `LabeledContent`, which a grouped form lays out as the
    /// row's trailing half: measured, 358pt wide against the classifier's 665pt, its text drawn
    /// right-aligned (seen in a capture; `NSTextView.alignment` still reported `.natural`).
    func testAgentsGuidanceEditorSpansTheRow() throws {
        let mounted = try mount(tab: .agents, rosterAgents: 1) {
            $0.modelGuidance = Self.guidance
            $0.autonomyEnabled = true
            $0.reviewLevel = .epic
        }

        let editors = mounted.collect(NSTextView.self)
        XCTAssertEqual(editors.map(\.string), [Self.guidance])
        let editor = try XCTUnwrap(editors.first)
        XCTAssertGreaterThanOrEqual(mounted.frame(of: editor).width, 600)
        XCTAssertGreaterThanOrEqual(mounted.frame(of: editor).height, 100)

        XCTAssertEqual(
            mounted.collect(NSPopUpButton.self).map(\.title),
            ["Claude Code default", ReviewLevel.epic.label]
        )
        XCTAssertEqual(mounted.collect(NSSwitch.self).map(\.state), [.on, .off], "autonomy, then the one rostered agent")
    }

    /// The reviewer picker is a radio group because a pop-up's options are unreadable offscreen; a
    /// radio's label is too, so each agent is identified by its position and moved selection.
    private func reviewerRadios(_ mounted: Mounted) -> [NSControl.StateValue] {
        mounted.collect(NSButton.self).filter { !($0 is NSPopUpButton) }.map(\.state)
    }

    /// Roster order puts Ada first; the project's own order puts Roscoe first. Elsewhere is on the
    /// roster but not this project's, so it must not be offered.
    func testAgentsReviewerPickerOffersThisProjectsAgentsInItsOrderAndShowsTheNamedOne() throws {
        let cases: [(named: String?, expected: [NSControl.StateValue])] = [
            (nil, [.on, .off, .off]),
            ("Roscoe", [.off, .on, .off]),
            ("Ada", [.off, .off, .on]),
        ]
        for (named, expected) in cases {
            let mounted = try mount(tab: .agents) { db, projectId in
                let roster = RosterStore(db)
                let ada = try roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
                let roscoe = try roster.create(name: "Roscoe", role: "go", systemPrompt: "p")
                try roster.create(name: "Elsewhere", role: "reviewer", systemPrompt: "p")
                try roster.enable(agentId: roscoe.id, forProject: projectId)
                try roster.enable(agentId: ada.id, forProject: projectId)
                let agent = [ada, roscoe].first { $0.name == named }
                var settings = try XCTUnwrap(ProjectStore(db).get(projectId)).settings
                settings.reviewAgent = agent.map { ReviewAgentChoice(id: $0.id, name: $0.name) }
                try ProjectStore(db).updateSettings(projectId, settings)
            }

            XCTAssertEqual(reviewerRadios(mounted), expected, "named \(named ?? "nobody")")
        }
    }

    func testAReviewerTheProjectNoLongerHasStaysOfferedAndSelectedLast() throws {
        let mounted = try mount(tab: .agents) { db, projectId in
            let roster = RosterStore(db)
            let ada = try roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
            try roster.enable(agentId: ada.id, forProject: projectId)
            var settings = try XCTUnwrap(ProjectStore(db).get(projectId)).settings
            settings.reviewAgent = ReviewAgentChoice(id: "deleted-agent", name: "Roscoe")
            try ProjectStore(db).updateSettings(projectId, settings)
        }

        XCTAssertEqual(reviewerRadios(mounted), [.off, .off, .on])
    }

    func testTheReviewerOptionsNameTheDefaultThenTheProjectsAgentsThenAMissingChoice() {
        let ada = RosterAgent(id: "a", name: "Ada", role: "frontend", systemPrompt: "p", createdAt: 0, updatedAt: 0)
        let off = RosterAgent(id: "o", name: "Otto", role: "go", systemPrompt: "p", enabled: false, createdAt: 0, updatedAt: 0)
        let options = ProjectSettingsSheet.reviewerOptions(
            projectAgents: [ada, off], current: ReviewAgentChoice(id: "gone", name: "Roscoe")
        )
        XCTAssertEqual(options.map(\.agentId), [nil, "a", "o", "gone"])
        XCTAssertEqual(
            options.map(\.title),
            [ProjectSettingsSheet.defaultReviewerTitle, "Ada", "Otto (disabled)", "Roscoe (not available)"]
        )
    }

    func testLimitsHoldsTheSixCapsInOrderAndNothingElse() throws {
        let mounted = try mount(tab: .limits) {
            $0.caps.maxConcurrentWorkers = 4
            $0.caps.maxTokensPerAgent = nil
            $0.caps.maxWallClockSeconds = 2400
            $0.caps.maxIdleSeconds = 450
            $0.caps.stallSeconds = 90
            $0.caps.sessionCeiling = 12
        }

        XCTAssertEqual(
            mounted.fields.map(\.stringValue),
            ["4", "", 2400.formatted(.number), "450", "90", "12"]
        )
        XCTAssertEqual(
            mounted.fields.map(\.placeholderString),
            [nil, "Unlimited", nil, nil, nil, "Unlimited"]
        )
        XCTAssertTrue(mounted.collect(NSPopUpButton.self).isEmpty)
        XCTAssertTrue(mounted.collect(NSSwitch.self).isEmpty)
        XCTAssertTrue(mounted.collect(NSTextView.self).isEmpty)
    }

    func testWorkflowHoldsCommandsStrategyAndBranchTemplate() throws {
        let mounted = try mount(tab: .workflow) {
            $0.buildCommand = "make"
            $0.worktreeStrategy = .shared
            $0.sharedCheckoutMaxAgents = 5
            $0.standaloneIntegration = .localMerge
        }

        XCTAssertEqual(mounted.fields.map(\.stringValue), ["make", "", "5", ""])
        XCTAssertEqual(
            mounted.fields.map(\.placeholderString),
            ["e.g. swift build", "e.g. swift test", nil, "e.g. clay/{slug}"]
        )
        XCTAssertEqual(
            mounted.collect(NSPopUpButton.self).map(\.title),
            [WorktreeStrategy.shared.title, StandaloneIntegration.localMerge.title]
        )
    }

    func testNotificationsHoldsOneSwitchPerCategoryInItsStoredState() throws {
        let mounted = try mount(tab: .notifications) {
            $0.notifications.setEnabled(.capsAndStalls, false)
        }

        XCTAssertEqual(
            mounted.collect(NSSwitch.self).map(\.state),
            NotificationCategory.allCases.map { $0 == .capsAndStalls ? .off : .on }
        )
        XCTAssertEqual(mounted.collect(NSPopUpButton.self).map(\.title), [NotificationMuteChoice.off.title])
        XCTAssertTrue(mounted.fields.isEmpty)
    }

    /// A `TextEditor` takes the system's smart quotes, so a typed `"` became `“` and the field
    /// reported "Not valid JSON." — measured on the old editor: quote and dash substitution both on.
    func testAdvancedClassifierEditorIsMonospacedTallAndTakesNoSmartSubstitutions() throws {
        let mounted = try mount(tab: .advanced) {
            $0.autoModeJSON = ProjectSettings.defaultAutoModeJSON
            $0.extraMcpServers = ["linear", "github"]
        }

        let editors = mounted.collect(NSTextView.self)
        XCTAssertEqual(editors.map(\.string), [ProjectSettings.defaultAutoModeJSON])
        let editor = try XCTUnwrap(editors.first)
        XCTAssertTrue(try XCTUnwrap(editor.font).fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertFalse(editor.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(editor.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(editor.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(editor.isRichText)
        XCTAssertGreaterThanOrEqual(mounted.frame(of: editor).width, 600)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        XCTAssertGreaterThanOrEqual(
            mounted.frame(of: scroll).height, mounted.frame(of: editor).height,
            "the shipped default classifier should fit without scrolling the editor"
        )
        XCTAssertEqual(mounted.fields.map(\.stringValue), ["linear, github"])
    }

    /// The old `TextEditor` took 256pt whatever its content; this pins a floor above that.
    func testAnEmptyClassifierStillGetsARoomyEditor() throws {
        let mounted = try mount(tab: .advanced)

        let scroll = try XCTUnwrap(mounted.collect(NSTextView.self).first?.enclosingScrollView)
        XCTAssertGreaterThanOrEqual(mounted.frame(of: scroll).height, 280)
    }

    /// A grouped form ends every field on the row's trailing edge; a `.frame(width:)` on one field
    /// would pull it off that line.
    func testEveryTabsFieldsEndOnOneTrailingEdge() throws {
        var edges: [String: CGFloat] = [:]
        for tab in ProjectSettingsTab.allCases {
            let mounted = try mount(tab: tab)
            for (n, field) in mounted.fields.enumerated() {
                edges["\(tab.title) field \(n)"] = mounted.frame(of: field).maxX
            }
        }
        XCTAssertGreaterThanOrEqual(edges.count, 12)
        let spread = (edges.values.max() ?? 0) - (edges.values.min() ?? 0)
        XCTAssertLessThanOrEqual(spread, 2, "trailing edges: \(edges.sorted { $0.key < $1.key })")
    }
}
