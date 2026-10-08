import AgentBoardCore
import AppKit
import SwiftUI
import Vision
import XCTest
@testable import AgentBoard

/// Mounts each settings tab offscreen and asserts on what that tab's controls hold.
///
/// Readable here: a text field's `stringValue` and `placeholderString`, a text view's string, font
/// and substitution flags, a switch's state, and every control's frame. Not readable: any `Text` —
/// labels, section headers and help text — so their wording, placement and wrapping were checked
/// only by looking at captures, never by this suite.
///
/// On macOS 27, in this offscreen/non-active session, a SwiftUI `Picker` no longer constructs an
/// `NSPopUpButton` at all — not renamed, not empty, just absent from the AppKit view tree, even
/// mounted through a real, on-screen, `makeKeyAndOrderFront`-ed window (see the headless UI
/// verification note). Every assertion that used to read a pop-up's selected title now reads the
/// same value one of two other ways instead:
///
/// - Where the picker's binding is a plain `@State` seeded once in `init` (archive mode, worktree
///   strategy, standalone integration, review level, default model), `seededState(_:_:)` reads it
///   off a freshly-constructed, never-mounted `ProjectSettingsSheet` through `Mirror` — see
///   `StateMirror.swift`. This cannot prove the picker actually renders bound to that state.
/// - Where the picker's rows depend on `projectAgents`, loaded from the database by a `.task` that
///   only runs once a view is live — reflecting the *unmounted* sheet always sees the empty default,
///   and reflecting it *after* mounting returns `nil` too (measured: SwiftUI moves `@State` storage
///   into the live render graph on mount, and the original struct's reflected box no longer holds
///   it) — the review-routing-table tests instead call `RosterStore.agents(forProject:)` and
///   `ProjectSettingsSheet.reviewerOptions`/`routingAssignee` directly, the same pure functions
///   `routingRow(_:)` calls, with the same database. This cannot prove `routingRow` actually calls
///   them with what it looks like it calls them with. Whether the `Group` around the routing rows is
///   still the thing `.disabled(settings.reviewLevel != .agent)` is attached to is read by
///   `testAgentsRoutingTableIsDisabledOutsideAgentReview` two ways, chosen per platform: where a real
///   `NSPopUpButton` exists (seen on macOS 26 CI) its `.isEnabled` is read directly; where none is
///   constructed at all (this machine, macOS 27) the test falls back to pixel contrast on the row's
///   drawn text.
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

    /// Builds the same project a `mount(tab:)` call would, but only constructs the
    /// `ProjectSettingsSheet` value — no `NSHostingView`, no window — for reading a `@State`
    /// property's seeded value through `seededState(_:_:)`.
    private func seededSheet(
        tab: ProjectSettingsTab,
        configure: (inout ProjectSettings) -> Void = { _ in }
    ) throws -> ProjectSettingsSheet {
        let db = try AppDatabase.inMemory()
        let projects = ProjectStore(db)
        var project = try projects.register(
            name: "Demo", repoPath: "/tmp/demo-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/demo-worktrees", memoryDir: nil
        )
        var settings = project.settings
        configure(&settings)
        try projects.updateSettings(project.id, settings)
        project = try XCTUnwrap(projects.get(project.id))
        return ProjectSettingsSheet(project: project, workspaces: [], initialTab: tab, onDeleted: {})
    }

    func testGeneralHoldsTheRepositoryFieldsWorkspaceAndArchive() throws {
        let mounted = try mount(tab: .general) { $0.archivePolicy = .afterDays(21) }

        XCTAssertEqual(mounted.fields.map(\.stringValue), ["main", "/tmp/demo-worktrees", "21"])
        XCTAssertTrue(mounted.collect(NSTextView.self).isEmpty)

        let sheet = try seededSheet(tab: .general) { $0.archivePolicy = .afterDays(21) }
        let archiveMode: ArchivePolicyMode? = seededState(sheet, "_archiveMode")
        XCTAssertEqual(archiveMode, .afterDays, "the archive picker's seeded state did not carry the stored policy")
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
        XCTAssertEqual(mounted.collect(NSSwitch.self).map(\.state), [.on, .off], "autonomy, then the one rostered agent")

        let sheet = try seededSheet(tab: .agents) {
            $0.modelGuidance = Self.guidance
            $0.autonomyEnabled = true
            $0.reviewLevel = .epic
        }
        let settings: ProjectSettings? = seededState(sheet, "_settings")
        XCTAssertEqual(settings?.defaultModel, nil, "no model override, so the picker should read Claude Code default")
        XCTAssertEqual(settings?.reviewLevel, .epic)
        let defaultRow = ProjectSettingsSheet.reviewerChoice(
            ProjectSettingsSheet.routingAssignee(settings?.reviewRouting ?? .init(), type: nil)
        )
        XCTAssertEqual(defaultRow, .anyReviewer, "an unconfigured routing table's default row")
        XCTAssertEqual(
            TaskType.allCases.map {
                ProjectSettingsSheet.reviewerChoice(
                    ProjectSettingsSheet.routingAssignee(settings?.reviewRouting ?? .init(), type: $0)
                )
            },
            Array(repeating: .sameAsDefault, count: TaskType.allCases.count),
            "an unconfigured routing table's per-type rows"
        )
    }

    /// Rex left the roster after being named; the Default row still shows him rather than a blank.
    ///
    /// This checks, for both review levels, that `routingRow`'s own logic — `routingAssignee` and
    /// `reviewerChoice` over a `ReviewRoutingTable` that has been through a real
    /// `ProjectStore.updateSettings`/`.get` round trip (JSON encode and decode), against a roster
    /// read back from `RosterStore.agents(forProject:)` — resolves each row's selected title the way
    /// the view is written to. It does not cover the `.disabled(settings.reviewLevel != .agent)` half
    /// of the original name — see `testAgentsRoutingTableIsDisabledOutsideAgentReview` below, which
    /// reads that through pixel contrast instead of the `NSPopUpButton.isEnabled` this session has none of.
    func testAgentsRoutingTableShowsEachRowsChoice() throws {
        for level in [ReviewLevel.agent, .epic] {
            let db = try AppDatabase.inMemory()
            let project = try ProjectStore(db).register(
                name: "Demo", repoPath: "/tmp/demo-\(UUID().uuidString)", baseBranch: "main",
                worktreeRoot: "/tmp/demo-worktrees", memoryDir: nil
            )
            let roster = RosterStore(db)
            let ada = try roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
            let roscoe = try roster.create(name: "Roscoe", role: "go", systemPrompt: "p")
            try roster.create(name: "Elsewhere", role: "reviewer", systemPrompt: "p")
            try roster.enable(agentId: roscoe.id, forProject: project.id)
            try roster.enable(agentId: ada.id, forProject: project.id)
            var settings = project.settings
            settings.reviewLevel = level
            settings.reviewRouting = ReviewRoutingTable(
                defaultAssignee: .named(ReviewAgentChoice(id: "deleted-agent", name: "Rex")),
                typeAssignees: [
                    .code: .named(ReviewAgentChoice(id: ada.id, name: ada.name)),
                    .plan: .acceptWithoutReview,
                    .review: .person,
                ]
            )
            try ProjectStore(db).updateSettings(project.id, settings)
            let reviewRouting = try XCTUnwrap(ProjectStore(db).get(project.id)).settings.reviewRouting
            let projectAgents = try roster.agents(forProject: project.id)

            let selectedTitles = ([nil] + TaskType.allCases).map { type -> String in
                let current = ProjectSettingsSheet.routingAssignee(reviewRouting, type: type)
                let choice = ProjectSettingsSheet.reviewerChoice(current)
                let options = ProjectSettingsSheet.reviewerOptions(
                    projectAgents: projectAgents, current: current?.namedChoice, sameAsDefault: type != nil
                )
                return options.first { $0.choice == choice }?.title ?? "<missing: \(choice)>"
            }
            XCTAssertEqual(
                selectedTitles,
                ["Rex (not available)", "Ada", "Same as Default", "Same as Default", "Accept without review", "A person"],
                "\(level)"
            )
        }
    }

    /// `.disabled(settings.reviewLevel != .agent)` wraps a `Group` of pickers, one per task type,
    /// each showing "Same as Default" while the routing table is unconfigured. On a build that still
    /// constructs a real `NSPopUpButton` for a `Picker` offscreen (macOS 26 CI, as of this writing),
    /// `.isEnabled` on that button is the strongest read of `.disabled(...)` there is, and is taken
    /// directly. On a build that does not (macOS 27, this machine — see the type-level doc comment:
    /// no pop-up button is constructed at all, not renamed, not empty, just absent), no such button
    /// exists to read, so this falls back to pixel contrast: a disabled control's text still draws,
    /// dimmed. That fallback sums the glyph ink in a per-type value's OCR box — every pixel's
    /// departure from the box's own background corner, not the box's single brightest pixel — and
    /// compares Agent review's ink against Epic review's ink directly, rather than against a fixed
    /// brightness threshold. A threshold assumes a particular background; summed deviation from the
    /// box's own corner does not, and a lone bright pixel (a caret, a stray anti-aliasing artifact)
    /// cannot dominate a sum the way it can a peak.
    ///
    /// Proven by mutation on the pixel fallback (this machine, macOS 27): deleting
    /// `.disabled(settings.reviewLevel != .agent)` from `ProjectSettingsSheet.swift` failed this test
    /// (Epic review's ink came back within the Agent-review floor — no longer dimmed); inverting it to
    /// `== .agent` also failed (Agent review came back dimmed instead, Epic review did not).
    func testAgentsRoutingTableIsDisabledOutsideAgentReview() throws {
        let enabled = try ocrRoutingCapture(reviewLevel: .agent)
        let disabled = try ocrRoutingCapture(reviewLevel: .epic)

        if !enabled.routingPopUps.isEmpty || !disabled.routingPopUps.isEmpty {
            XCTAssertFalse(enabled.routingPopUps.isEmpty, "expected per-type routing pop-up buttons at Agent review")
            XCTAssertFalse(disabled.routingPopUps.isEmpty, "expected per-type routing pop-up buttons at Epic review")
            XCTAssertTrue(
                enabled.routingPopUps.allSatisfy(\.isEnabled),
                "Agent review's routing pop-up buttons should be enabled"
            )
            XCTAssertTrue(
                disabled.routingPopUps.allSatisfy { !$0.isEnabled },
                "a routing pop-up button is not disabled outside Agent review"
            )
            return
        }

        let enabledInk = try glyphInk(enabled)
        let disabledInk = try glyphInk(disabled)
        XCTAssertGreaterThan(enabledInk, 1000, "Agent review's routing row drew too little glyph ink to compare: \(enabledInk)")
        XCTAssertGreaterThan(
            enabledInk, disabledInk * 2,
            "the routing row is not clearly dimmer outside Agent review: enabled ink \(enabledInk), disabled ink \(disabledInk)"
        )
    }

    private struct OCRLine {
        let text: String
        let box: CGRect
    }

    /// Mounts the Agents tab at the given review level and reads it two ways: Vision OCR (to find
    /// where a routing row's value text sits, for the pixel fallback) and a walk for the per-type
    /// routing `Picker`s' `NSPopUpButton`s, where the platform still constructs one. No roster agent
    /// is needed — an unconfigured `ReviewRoutingTable` already renders "Same as Default" for every
    /// task type, which is also how the per-type pop-up buttons are told apart from the Default row's
    /// (which never reads "Same as Default" — see `ProjectSettingsSheet.routingRow`) and from every
    /// other pop-up button on the tab.
    /// Waits not just for pixels to stop moving but for at least one per-type routing row to show its
    /// "Same as Default" value — the same `Picker`-backed `NSPopUpButton` lag `typeRowHasValue(in:)`
    /// guards against in `TaskTypeRenderTests`. Without this, `mount.capture()` can agree on a frame
    /// drawn before any routing picker has painted its title, and `glyphInk` then fails loudly with
    /// "no per-type routing value found" instead of comparing real ink.
    private func ocrRoutingCapture(
        reviewLevel: ReviewLevel
    ) throws -> (lines: [OCRLine], rep: NSBitmapImageRep, routingPopUps: [NSPopUpButton]) {
        let db = try AppDatabase.inMemory()
        let projects = ProjectStore(db)
        var project = try projects.register(
            name: "Demo", repoPath: "/tmp/demo-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/demo-worktrees", memoryDir: nil
        )
        var settings = project.settings
        settings.reviewLevel = reviewLevel
        try projects.updateSettings(project.id, settings)
        project = try XCTUnwrap(projects.get(project.id))

        let view = ProjectSettingsSheet(project: project, workspaces: [], initialTab: .agents, onDeleted: {})
            .environment(renderEnvironment(db: db))
        let mount = OffscreenMount(view, size: CGSize(width: 780, height: 900))
        defer { mount.close() }
        var lines: [OCRLine] = []
        var lastImage: CGImage?
        _ = try mount.capture(until: { _ in
            guard let image = CGWindowListCreateImage(
                .null, .optionIncludingWindow, CGWindowID(mount.window.windowNumber),
                [.boundsIgnoreFraming, .bestResolution]
            ) else { return false }
            lastImage = image
            guard let recognized = try? self.recognizedRoutingLines(in: image) else { return false }
            lines = recognized
            return recognized.contains { $0.text.contains(ProjectSettingsSheet.sameAsDefaultTitle) }
        })
        let routingPopUps = popUpButtons(titled: ProjectSettingsSheet.sameAsDefaultTitle, in: mount.host)
        let image = try XCTUnwrap(lastImage, "no window-server image captured")
        let rep = try XCTUnwrap(NSBitmapImageRep(cgImage: image))
        return (lines, rep, routingPopUps)
    }

    private func recognizedRoutingLines(in image: CGImage) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { OCRLine(text: $0.string, box: observation.boundingBox) }
        }
    }

    private func popUpButtons(titled title: String, in host: NSView) -> [NSPopUpButton] {
        var found: [NSPopUpButton] = []
        func walk(_ view: NSView) {
            if let button = view as? NSPopUpButton, button.title == title { found.append(button) }
            view.subviews.forEach(walk)
        }
        walk(host)
        return found
    }

    /// Sum, over a per-type routing row's "Same as Default" OCR box, of each pixel's brightness
    /// departure from the box's own top-left corner (its background). The glyph strokes are what
    /// create that departure; summing rather than peaking means one stray bright pixel cannot stand
    /// in for the whole row, and starting from the box's own corner rather than a fixed threshold
    /// means the metric does not assume which appearance (light or dark mode) it is reading.
    private func glyphInk(
        _ capture: (lines: [OCRLine], rep: NSBitmapImageRep, routingPopUps: [NSPopUpButton])
    ) throws -> Int {
        let value = try XCTUnwrap(
            capture.lines.first { $0.text.contains("Same as Default") },
            "no per-type routing value found: \(capture.lines.map(\.text))"
        )
        let rep = capture.rep
        let box = value.box
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0 else { return 0 }
        let x0 = max(0, Int(box.minX * CGFloat(w)))
        let x1 = min(w, Int(box.maxX * CGFloat(w)))
        let yTop = max(0, h - Int(box.maxY * CGFloat(h)))
        let yBottom = min(h, h - Int(box.minY * CGFloat(h)))
        guard x0 < x1, yTop < yBottom, let background = rep.colorAt(x: x0, y: yTop) else { return 0 }
        let backgroundLuma = (background.redComponent + background.greenComponent + background.blueComponent) / 3 * 255
        var ink = 0
        for y in yTop..<yBottom {
            for x in x0..<x1 {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let luma = (color.redComponent + color.greenComponent + color.blueComponent) / 3 * 255
                ink += Int(abs(luma - backgroundLuma))
            }
        }
        return ink
    }

    func testTheReviewerOptionsListTheProjectsAgentsThenAMissingChoiceThenTheFixedChoices() {
        let ada = RosterAgent(id: "a", name: "Ada", role: "frontend", systemPrompt: "p", createdAt: 0, updatedAt: 0)
        let off = RosterAgent(id: "o", name: "Otto", role: "go", systemPrompt: "p", enabled: false, createdAt: 0, updatedAt: 0)
        let fixed = [
            ProjectSettingsSheet.anyReviewerTitle, ProjectSettingsSheet.personTitle,
            ProjectSettingsSheet.acceptWithoutReviewTitle,
        ]
        let typeRow = ProjectSettingsSheet.reviewerOptions(
            projectAgents: [ada, off], current: ReviewAgentChoice(id: "gone", name: "Roscoe"), sameAsDefault: true
        )
        XCTAssertEqual(
            typeRow.map(\.title),
            [ProjectSettingsSheet.sameAsDefaultTitle, "Ada", "Otto (disabled)", "Roscoe (not available)"] + fixed
        )
        let defaultRow = ProjectSettingsSheet.reviewerOptions(projectAgents: [ada], current: nil, sameAsDefault: false)
        XCTAssertEqual(defaultRow.map(\.title), ["Ada"] + fixed)
    }

    func testEditingARoutingRowRoundTripsThroughSettingsEncoding() {
        let ada = RosterAgent(id: "a", name: "Ada", role: "frontend", systemPrompt: "p", createdAt: 0, updatedAt: 0)
        var settings = ProjectSettings()
        settings.reviewRouting.typeAssignees[.code] = .person
        ProjectSettingsSheet.setRouting(&settings.reviewRouting, type: .docs, to: .named(agentId: "a"), projectAgents: [ada])
        ProjectSettingsSheet.setRouting(&settings.reviewRouting, type: .code, to: .sameAsDefault, projectAgents: [ada])
        ProjectSettingsSheet.setRouting(&settings.reviewRouting, type: nil, to: .acceptWithoutReview, projectAgents: [ada])

        let decoded = ProjectSettings.decode(settings.encoded()).reviewRouting
        XCTAssertEqual(
            decoded,
            ReviewRoutingTable(
                defaultAssignee: .acceptWithoutReview,
                typeAssignees: [.docs: .named(ReviewAgentChoice(id: "a", name: "Ada"))]
            )
        )
        XCTAssertEqual(
            [nil, TaskType.code, .docs].map { ProjectSettingsSheet.reviewerChoice(ProjectSettingsSheet.routingAssignee(decoded, type: $0)) },
            [.acceptWithoutReview, .sameAsDefault, .named(agentId: "a")]
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

        let sheet = try seededSheet(tab: .workflow) {
            $0.worktreeStrategy = .shared
            $0.standaloneIntegration = .localMerge
        }
        let settings: ProjectSettings? = seededState(sheet, "_settings")
        XCTAssertEqual(settings?.worktreeStrategy, .shared)
        XCTAssertEqual(settings?.standaloneIntegration, .localMerge)
    }

    func testNotificationsHoldsOneSwitchPerCategoryInItsStoredState() throws {
        let mounted = try mount(tab: .notifications) {
            $0.notifications.setEnabled(.capsAndStalls, false)
        }

        XCTAssertEqual(
            mounted.collect(NSSwitch.self).map(\.state),
            NotificationCategory.allCases.map { $0 == .capsAndStalls ? .off : .on }
        )
        XCTAssertTrue(mounted.fields.isEmpty)

        let sheet = try seededSheet(tab: .notifications) { $0.notifications.setEnabled(.capsAndStalls, false) }
        let muteChoice: NotificationMuteChoice? = seededState(sheet, "_muteChoice")
        XCTAssertEqual(muteChoice, .off)
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
