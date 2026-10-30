import AgentBoardCore
import AgentBoardRuntime
import AppKit
import SwiftUI

/// The Pull Requests page (SPEC §13.4): every watched pull request across projects, grouped by
/// where it is in follow-through.
struct PullRequestsView: View {
    let projects: [Project]
    /// Owned by `MainWindow`, so At a Glance and a banner click can open the page already filtered.
    @Binding var projectFilter: String?

    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @State private var page = Observed<[PRWatchGroup]>([])
    @State private var marking: Set<String> = []
    @State private var errorMessage: String?
    @State private var routedWatchId: String?
    @State private var refreshing: Set<PRPageGroup> = []
    @State private var refreshErrors: [PRPageGroup: String] = [:]
    @State private var showsStopped = false

    init(projects: [Project], projectFilter: Binding<String?> = .constant(nil)) {
        self.projects = projects
        _projectFilter = projectFilter
    }

    static func sections(_ groups: [PRWatchGroup]) -> [PRWatchGroup] {
        PRPageGroup.allCases.compactMap { group in
            if let found = groups.first(where: { $0.group == group }) { return found }
            return group.hidesWhenEmpty ? nil : PRWatchGroup(group: group, listings: [])
        }
    }

    /// Projects with follow-through on, plus the filtered one in case it was since turned off.
    private var filterable: [Project] {
        projects.filter { $0.settings.prFollowThrough.enabled || $0.id == projectFilter }
    }

    private var projectsById: [String: Project] {
        Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var actions: PullRequestActions { PullRequestActions(db: env.db, gh: env.gh) }

    var body: some View {
        Group {
            if filterable.isEmpty && page.value.isEmpty {
                ContentUnavailableView(
                    "No pull requests watched",
                    systemImage: "arrow.triangle.pull",
                    description: Text("Turn on PR follow-through in a project's settings to watch the pull requests you open there.")
                )
            } else {
                list
            }
        }
        .navigationTitle("Pull Requests")
        .task(id: projectFilter) {
            await page.run(PRWatchStore(env.db).observePage(projectId: projectFilter), in: env.db.reader)
        }
        .task(id: env.router.sequence) {
            guard let route = env.router.route, case .pullRequest(let watchId) = route.subject,
                  env.router.take(.pullRequestRow, projectId: route.projectId) != nil
            else { return }
            routedWatchId = watchId
        }
        .errorAlert($errorMessage)
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Project", selection: $projectFilter) {
                    Text("All projects").tag(String?.none)
                    ForEach(filterable) { Text($0.name).tag(String?.some($0.id)) }
                }
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Self.sections(page.value), id: \.group) { section in
                        Section {
                            if let error = refreshErrors[section.group] {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            if section.listings.isEmpty {
                                Text(section.group.emptyText)
                                    .foregroundStyle(.secondary)
                            }
                            if section.group != .stopped || showsStopped {
                                ForEach(section.listings) { listing in
                                    row(listing)
                                }
                            }
                        } header: {
                            header(section)
                        }
                    }
                }
                .onChange(of: routedWatchId) { scrollToRoutedRow(proxy) }
                .onChange(of: page.value) { scrollToRoutedRow(proxy) }
            }
        }
    }

    private func header(_ section: PRWatchGroup) -> some View {
        let title = section.group.title
        let inFlight = refreshing.contains(section.group) || env.supervisor.isPollingPRWatches
        return HStack {
            if section.group == .stopped {
                Button {
                    showsStopped.toggle()
                } label: {
                    Label("\(title) (\(section.listings.count))", systemImage: showsStopped ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                .accessibilityValue(showsStopped ? "Expanded" : "Collapsed")
                .help(showsStopped ? "Hide the pull requests you stopped watching" : "Show the pull requests you stopped watching")
            } else {
                Text(title)
            }
            Spacer()
            if inFlight {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing \(title)")
            }
            Button("Refresh", systemImage: "arrow.clockwise") { refresh(section) }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderless)
                .disabled(section.listings.isEmpty)
                .accessibilityLabel("Refresh \(title)")
                .accessibilityValue(inFlight ? "Refreshing" : "")
                .help("Poll GitHub now for the pull requests in \(title)")
        }
    }

    /// SPEC §13.4: polls this section's watches now; a press during a poll joins it.
    private func refresh(_ section: PRWatchGroup) {
        let group = section.group
        let ids = Set(section.listings.map(\.id))
        refreshing.insert(group)
        refreshErrors[group] = nil
        AccessibilityNotification.Announcement("Refreshing \(group.title)").post()
        _Concurrency.Task {
            defer { refreshing.remove(group) }
            do {
                try await env.supervisor.pollPRWatches(watchIds: ids)
                AccessibilityNotification.Announcement("\(group.title) refreshed").post()
            } catch {
                refreshErrors[group] = errorText(error)
                AccessibilityNotification.Announcement("Refreshing \(group.title) failed: \(errorText(error))").post()
            }
        }
    }

    /// The routed row may arrive after the route does, once the filtered page has loaded.
    private func scrollToRoutedRow(_ proxy: ScrollViewProxy) {
        guard let id = routedWatchId,
              page.value.contains(where: { $0.listings.contains { $0.id == id } })
        else { return }
        proxy.scrollTo(id, anchor: .center)
        routedWatchId = nil
    }

    private func row(_ listing: PRWatchListing) -> some View {
        let project = projectsById[listing.watch.projectId]
        let followThrough = project?.settings.prFollowThrough ?? PRFollowThroughSettings()
        return VStack(alignment: .leading, spacing: 8) {
            PullRequestRow(
                listing: listing,
                projectName: projectFilter == nil ? project?.name : nil,
                verificationLabel: followThrough.markVerifiedLabel,
                canWalkThrough: followThrough.verifyCommand(for: listing.watch.url) != nil,
                isMarking: marking.contains(listing.id),
                markVerified: { markVerified(listing.watch, project: project) },
                walkThrough: { openWindow(id: PRVerifyScene.id, value: listing.watch.id) },
                sendBack: { sendBack(listing.watch, failure: $0) },
                togglePause: { togglePause(listing.watch) },
                resume: { perform { try actions.resume(listing.watch) } },
                stopWatching: { perform { try actions.stopWatching(listing.watch) } }
            )
            ForEach(listing.decisions) { decision in
                PRDecisionRow(decision: decision) { choice in
                    await answer(decision, choice: choice)
                }
            }
            if !listing.items.isEmpty {
                PRItemList(items: listing.items) { item, reason in
                    await dismiss(item, reason: reason)
                }
            }
        }
    }

    private func dismiss(_ item: PRItem, reason: String) async -> Bool {
        guard let id = item.id else { return false }
        do {
            try await env.supervisor.dismissPRItem(itemId: id, reason: reason)
            return true
        } catch {
            errorMessage = errorText(error)
            return false
        }
    }

    private func answer(_ decision: PRItem, choice: PRDecisionChoice) async -> Bool {
        guard let id = decision.id else { return false }
        do {
            try await env.supervisor.answerPRDecision(itemId: id, choice: choice)
            return true
        } catch {
            errorMessage = errorText(error)
            return false
        }
    }

    private func markVerified(_ watch: PRWatch, project: Project?) {
        guard let project else { return }
        marking.insert(watch.id)
        _Concurrency.Task {
            defer { marking.remove(watch.id) }
            do {
                try await actions.markVerified(watch, project: project)
            } catch {
                errorMessage = errorText(error)
            }
        }
    }

    private func sendBack(_ watch: PRWatch, failure: String) -> Bool {
        do {
            try actions.sendBack(watch, failure: failure)
            return true
        } catch {
            errorMessage = errorText(error)
            return false
        }
    }

    private func togglePause(_ watch: PRWatch) {
        perform { try actions.setPaused(!watch.paused, watch: watch) }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = errorText(error)
        }
    }
}

/// The page's row actions apart from the view, so a test can drive them against a fake `gh`.
@MainActor
struct PullRequestActions {
    let db: AppDatabase
    let gh: any GhRunning

    /// Adds the project's verification label, then records the PR as verified. Without a label
    /// there is nothing to add, so nothing runs; the button is disabled for that case.
    func markVerified(_ watch: PRWatch, project: Project) async throws {
        guard let label = project.settings.prFollowThrough.markVerifiedLabel else { return }
        let labeler = PullRequestLabeler(gh: gh)
        let url = watch.url
        let cwd = URL(fileURLWithPath: project.repoPath)
        try await _Concurrency.Task.detached(priority: .userInitiated) {
            try labeler.addLabel(label, to: url, cwd: cwd)
        }.value
        try PRWatchStore(db).markVerified(watchId: watch.id, label: label)
    }

    /// Records what verifying the PR turned up as a verify failure (SPEC §13.1).
    func sendBack(_ watch: PRWatch, failure: String) throws {
        try PRWatchStore(db).addVerifyFailure(watchId: watch.id, body: failure)
    }

    func setPaused(_ paused: Bool, watch: PRWatch) throws {
        try PRWatchStore(db).setPaused(paused, watchId: watch.id)
    }

    func resume(_ watch: PRWatch) throws {
        try PRWatchStore(db).resume(watchId: watch.id)
    }

    func stopWatching(_ watch: PRWatch) throws {
        try PRWatchStore(db).stopWatching(watchId: watch.id)
    }

}

/// A row's open items, collapsed under it, each with **Dismiss…** (SPEC §13.4).
struct PRItemList: View {
    let items: [PRItem]
    /// Returns whether the dismissal was recorded.
    let dismiss: (PRItem, String) async -> Bool

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(items) { item in
                PRItemRow(item: item) { await dismiss(item, $0) }
            }
        } label: {
            Text(items.count == 1 ? "1 open item" : "\(items.count) open items")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 16)
    }
}

/// One open item: its author, kind and first line, so the right one gets dismissed.
struct PRItemRow: View {
    let item: PRItem
    let dismiss: (String) async -> Bool

    @State private var dismissing = false
    @State private var submitting = false
    @State private var reason = ""

    private var trimmedReason: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(summary)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(item.body)
            Spacer(minLength: 8)
            Button("Dismiss…") { dismissing = true }
                .controlSize(.small)
                .accessibilityLabel("Dismiss item \(item.id ?? 0)")
                .help("Retire this item with a reason: no fix, no reply, and no later check grades it")
                .popover(isPresented: $dismissing, arrowEdge: .bottom) { form }
        }
    }

    var summary: String {
        var parts = [item.author, item.kind.rawValue.replacingOccurrences(of: "_", with: " ")].compactMap { $0 }
        if let grade = item.followupGrade, grade == .partly || grade == .notFixed {
            parts.append("graded \(grade.rawValue.replacingOccurrences(of: "_", with: " "))")
        }
        parts.append(item.firstLine())
        return parts.joined(separator: " · ")
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Why does this item need nothing more?")
                .fontWeight(.semibold)
            TextField("Reason", text: $reason)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { dismissing = false }
                    .keyboardShortcut(.cancelAction)
                Button("Dismiss", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedReason.isEmpty || submitting)
            }
        }
        .padding(12)
    }

    private func submit() {
        guard !trimmedReason.isEmpty, !submitting else { return }
        submitting = true
        _Concurrency.Task {
            defer { submitting = false }
            guard await dismiss(trimmedReason) else { return }
            reason = ""
            dismissing = false
        }
    }
}

/// One open decision under its pull request's row (SPEC §13.4): the comment, triage's question, an
/// option button for each choice, which answers it as that option's fix or reply, and a reply that
/// answers it in words.
struct PRDecisionRow: View {
    let decision: PRItem
    /// Returns whether the answer was recorded.
    let answer: (PRDecisionChoice) async -> Bool

    @State private var reply = ""

    private var trimmedReply: String { reply.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(excerpt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(decision.decisionQuestion ?? "Triage asked for a decision.")
                .fontWeight(.semibold)
            ViewThatFits(in: .horizontal) {
                HStack { options }
                VStack(alignment: .leading) { options }
            }
            HStack {
                TextField("Reply instead", text: $reply)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendReply)
                Button("Send reply", action: sendReply)
                    .disabled(trimmedReply.isEmpty)
                    .help("Answer the reviewer with this text; no code changes")
            }
        }
        .padding(.leading, 16)
        .padding(.vertical, 4)
    }

    private var options: some View {
        ForEach(decision.decisionOptions, id: \.self) { option in
            Button(option.label) { _Concurrency.Task { _ = await answer(.option(option.label)) } }
                .help(option.verdict == .answer ? "Reply: \(option.replyBody ?? "")" : "Fix the comment this way")
        }
    }

    private var excerpt: String {
        let body = decision.body.split(whereSeparator: \.isNewline).joined(separator: " ")
        return decision.author.map { "\($0): \(body)" } ?? body
    }

    private func sendReply() {
        guard !trimmedReply.isEmpty else { return }
        let text = trimmedReply
        _Concurrency.Task {
            if await answer(.reply(text)) { reply = "" }
        }
    }
}

struct PullRequestRow: View {
    let listing: PRWatchListing
    /// Shown only while the page lists every project.
    let projectName: String?
    let verificationLabel: String?
    let canWalkThrough: Bool
    let isMarking: Bool
    let markVerified: () -> Void
    let walkThrough: () -> Void
    /// Returns whether the failure was recorded.
    let sendBack: (String) -> Bool
    let togglePause: () -> Void
    let resume: () -> Void
    let stopWatching: () -> Void

    @Environment(\.openWindow) private var openWindow
    @State private var sendingBack = false
    @State private var failure = ""

    private var watch: PRWatch { listing.watch }
    private var canSendBack: Bool { watch.state == .readyToVerify || watch.state == .verified }
    private var trimmedFailure: String { failure.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isParked: Bool { watch.state == .parked }
    private var isStopped: Bool { watch.state == .stopped }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Button(watch.title) {
                    if let url = URL(string: watch.url) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.link)
                .help(watch.url)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isParked {
                    Text(watch.parkedReason ?? "Follow-through parked this pull request.")
                        .font(.caption)
                        .lineLimit(4)
                }
            }
            Spacer(minLength: 8)
            ForEach(listing.sessions) { session in
                attachButton(session)
            }
            if watch.state != .verified && !isStopped {
                Button(isMarking ? "Marking…" : "Mark verified", action: markVerified)
                    .disabled(verificationLabel == nil || isMarking)
                    .help(verificationLabel.map { "Add the \($0) label on GitHub" }
                        ?? "This project sets no verification label; merging is the verification.")
            }
            if canWalkThrough {
                Button("Walk me through it", action: walkThrough)
                    .help("Run this project's verify command for this pull request in a new terminal window")
            }
            if canSendBack {
                Button("Send back") { sendingBack = true }
                    .help(watch.state == .verified
                        ? "Record what verifying turned up; the PR stays frozen until you remove the label"
                        : "Record what verifying turned up, so follow-through fixes it")
                    .popover(isPresented: $sendingBack, arrowEdge: .bottom) { sendBackForm }
            }
            if isStopped {
                Button("Watch again", action: resume)
                    .help("Start follow-through on this pull request again, with a fresh round cap")
            } else if isParked {
                Button("Resume", action: resume)
                    .help("Start follow-through on this pull request again, with a fresh round cap")
                Button("Stop watching", action: stopWatching)
                    .help("Leave this pull request to you; it moves to Stopped until you choose Watch again")
            } else {
                Button(watch.paused ? "Resume" : "Pause", action: togglePause)
            }
        }
        .padding(.vertical, 2)
    }

    /// SPEC §13.4: opens the session's terminal window, as the Status page's attach button does.
    private func attachButton(_ session: PRListingSession) -> some View {
        let attach = SessionAction.attach
        return Button {
            openWindow(id: "terminal", value: session.sessionId)
        } label: {
            Label(session.role.title, systemImage: attach.symbol)
        }
        .accessibilityLabel("\(attach.accessibilityLabel): \(session.role.title)")
        .help("Attach to the \(session.role.title.lowercased()) agent's Claude session")
    }

    private var sendBackForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What failed?")
                .fontWeight(.semibold)
            TextField("What you did, what you expected, what happened", text: $failure, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(4...10)
                .frame(width: 360)
            HStack {
                Spacer()
                Button("Cancel") { sendingBack = false }
                    .keyboardShortcut(.cancelAction)
                Button("Send back", action: submitSendBack)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedFailure.isEmpty)
            }
        }
        .padding(12)
    }

    private func submitSendBack() {
        guard !trimmedFailure.isEmpty, sendBack(trimmedFailure) else { return }
        failure = ""
        sendingBack = false
    }

    private var details: String {
        var parts = ["\(watch.repoOwner)/\(watch.repoName) #\(watch.number)", watch.state.title]
        if watch.state == .stale { parts.append("restarted: head moved") }
        if watch.round > 0 { parts.append("round \(watch.round)") }
        parts.append(listing.openItems == 1 ? "1 open item" : "\(listing.openItems) open items")
        if let pushed = watch.headChangedAt {
            parts.append("pushed \(Format.relative(Date(timeIntervalSince1970: TimeInterval(pushed) / 1000)))")
        } else {
            parts.append("updated \(Format.relative(Date(timeIntervalSince1970: TimeInterval(watch.updatedAt) / 1000)))")
        }
        if let polled = watch.lastPolledAt {
            parts.append("polled \(Format.relative(Date(timeIntervalSince1970: TimeInterval(polled) / 1000)))")
        }
        if watch.paused { parts.append("paused") }
        if let projectName { parts.append(projectName) }
        return parts.joined(separator: " · ")
    }
}

extension PRPageGroup {
    var title: String {
        switch self {
        case .readyToVerify: "Ready to verify"
        case .needsYou: "Needs you"
        case .inProgress: "In progress"
        case .waitingOnReviewers: "Waiting on reviewers"
        case .verified: "Verified"
        case .parked: "Parked"
        case .stopped: "Stopped"
        }
    }

    var emptyText: String {
        switch self {
        case .readyToVerify: "Nothing is ready to verify."
        case .needsYou: "Nothing needs you."
        case .inProgress: "Nothing is in progress."
        case .waitingOnReviewers: "Nothing is waiting on reviewers."
        case .verified: "Nothing is verified yet."
        case .parked: "Nothing is parked."
        case .stopped: "Nothing is stopped."
        }
    }
}

extension PRSessionRole {
    var title: String {
        switch self {
        case .triage: "Triage"
        case .fixer: "Fixer"
        case .reviewer: "Reviewer"
        }
    }
}

extension PRWatchState {
    var title: String {
        switch self {
        case .watching: "watching"
        case .settling: "settling"
        case .triaging: "triaging"
        case .fixing: "fixing"
        case .checking: "checking"
        case .publishing: "publishing"
        case .awaitingCI: "awaiting CI"
        case .readyToVerify: "ready to verify"
        case .verified: "verified"
        case .stale: "stale"
        case .parked: "parked"
        case .merged: "merged"
        case .closed: "closed"
        case .stopped: "stopped"
        }
    }
}
