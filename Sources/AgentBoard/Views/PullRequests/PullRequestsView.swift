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
                        Section(section.group.title) {
                            if section.listings.isEmpty {
                                Text(section.group.emptyText)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(section.listings) { listing in
                                row(listing)
                            }
                        }
                    }
                }
                .onChange(of: routedWatchId) { scrollToRoutedRow(proxy) }
                .onChange(of: page.value) { scrollToRoutedRow(proxy) }
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
                togglePause: { togglePause(listing.watch) }
            )
            ForEach(listing.decisions) { decision in
                PRDecisionRow(decision: decision) { answer, verdict in
                    self.answer(decision, with: answer, verdict: verdict, project: project)
                }
            }
        }
    }

    private func answer(_ decision: PRItem, with answer: String, verdict: PRItemVerdict, project: Project?) -> Bool {
        do {
            try actions.answer(decision, with: answer, verdict: verdict, project: project)
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

    private func togglePause(_ watch: PRWatch) {
        do {
            try actions.setPaused(!watch.paused, watch: watch)
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

    func setPaused(_ paused: Bool, watch: PRWatch) throws {
        try PRWatchStore(db).setPaused(paused, watchId: watch.id)
    }

    func answer(_ decision: PRItem, with answer: String, verdict: PRItemVerdict, project: Project?) throws {
        guard let id = decision.id else { return }
        let fixer = project?.settings.prFollowThrough.roles.fixer
        try Board(db).answerDecision(
            itemId: id, answer: answer, verdict: verdict, fixerModel: fixer?.model ?? project?.settings.defaultModel
        )
    }
}

/// One open decision under its pull request's row (SPEC §13.4): the comment, triage's question, an
/// option button for each choice, which answers it as a fix, and a reply that answers it in words.
struct PRDecisionRow: View {
    let decision: PRItem
    /// Returns whether the answer was recorded.
    let answer: (String, PRItemVerdict) -> Bool

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
            Button(option) { _ = answer(option, .fix) }
                .help("Fix the comment this way")
        }
    }

    private var excerpt: String {
        let body = decision.body.split(whereSeparator: \.isNewline).joined(separator: " ")
        return decision.author.map { "\($0): \(body)" } ?? body
    }

    private func sendReply() {
        guard !trimmedReply.isEmpty else { return }
        if answer(trimmedReply, .answer) { reply = "" }
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
    let togglePause: () -> Void

    private var watch: PRWatch { listing.watch }

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
            }
            Spacer(minLength: 8)
            if watch.state != .verified {
                Button(isMarking ? "Marking…" : "Mark verified", action: markVerified)
                    .disabled(verificationLabel == nil || isMarking)
                    .help(verificationLabel.map { "Add the \($0) label on GitHub" }
                        ?? "This project sets no verification label; merging is the verification.")
            }
            if canWalkThrough {
                Button("Walk me through it", action: walkThrough)
                    .help("Run this project's verify command for this pull request in a new terminal window")
            }
            Button(watch.paused ? "Resume" : "Pause", action: togglePause)
        }
        .padding(.vertical, 2)
    }

    private var details: String {
        var parts = ["\(watch.repoOwner)/\(watch.repoName) #\(watch.number)", watch.state.title]
        if watch.round > 0 { parts.append("round \(watch.round)") }
        parts.append(listing.openItems == 1 ? "1 open item" : "\(listing.openItems) open items")
        if let pushed = watch.headChangedAt {
            parts.append("pushed \(Format.relative(Date(timeIntervalSince1970: TimeInterval(pushed) / 1000)))")
        } else {
            parts.append("updated \(Format.relative(Date(timeIntervalSince1970: TimeInterval(watch.updatedAt) / 1000)))")
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
        }
    }
}
