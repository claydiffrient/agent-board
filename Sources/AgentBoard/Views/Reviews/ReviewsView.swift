import AgentBoardRuntime
import AppKit
import SwiftUI

/// The Reviews page (SPEC §10, §13.7): what CDR, the review watcher, is running and queued now, its
/// recent reviews, and a toggle that starts and stops its daemon.
struct ReviewsView: View {
    var pollInterval: Duration = .seconds(10)

    @Environment(AppEnvironment.self) private var env
    @AppStorage(CDRSettings.commandKey) private var configuredCommand = ""
    @State private var model = ReviewsModel()

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            List {
                ForEach(ReviewsPage.sections(model.snapshot)) { section in
                    Section {
                        if let message = section.message {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if section.rows.isEmpty {
                            Text(section.emptyText)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(section.rows) { ReviewsRow(row: $0) }
                    } header: {
                        Text(section.title)
                    }
                }
            }
        }
        .navigationTitle("Reviews")
        .task {
            guard let cdr = env.cdr else { return }
            while !_Concurrency.Task.isCancelled {
                await model.refresh(cdr)
                try? await _Concurrency.Task.sleep(for: pollInterval)
            }
        }
        .task(id: configuredCommand) {
            guard let cdr = env.cdr else { return }
            await model.resolveCommand(configured: configuredCommand, cdr: cdr)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Toggle("CDR daemon", isOn: Binding(
                    get: { model.toggleIsOn },
                    set: { running in
                        guard let cdr = env.cdr else { return }
                        _Concurrency.Task { await model.setDaemon(running: running, cdr: cdr) }
                    }
                ))
                .toggleStyle(.switch)
                .disabled(!model.canToggle)
                .fixedSize()
                if model.pendingRunning != nil {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(model.pendingRunning == true ? "Starting CDR" : "Stopping CDR")
                }
                Text(ReviewsPage.statusLine(model.snapshot?.daemon))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            }
            if let error = model.commandError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if case .failure(let failure) = model.command {
                HStack {
                    Text(failure.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SettingsLink { Text("Open Settings…") }
                        .controlSize(.small)
                }
            }
        }
    }
}

/// The Reviews page's state apart from the view, so a test can drive the toggle against a fake CDR.
@Observable
@MainActor
final class ReviewsModel {
    private(set) var snapshot: CDRSnapshot?
    private(set) var command: Result<CDRCommand, CDRCommandError>?
    /// Where the toggle was switched to, while CDR's CLI runs.
    private(set) var pendingRunning: Bool?
    /// CDR's stderr from the last start or stop that failed.
    private(set) var commandError: String?

    var toggleIsOn: Bool {
        if let pendingRunning { return pendingRunning }
        if case .running = snapshot?.daemon { return true }
        return false
    }

    var canToggle: Bool {
        guard pendingRunning == nil, case .success = command, let daemon = snapshot?.daemon else { return false }
        return daemon != .notInstalled
    }

    func refresh(_ cdr: any CDRService) async {
        snapshot = await cdr.snapshot()
    }

    func resolveCommand(configured: String, cdr: any CDRService) async {
        command = await _Concurrency.Task.detached { cdr.resolveCommand(configured: configured) }.value
    }

    func setDaemon(running: Bool, cdr: any CDRService) async {
        guard pendingRunning == nil, case .success(let command) = command else { return }
        pendingRunning = running
        commandError = nil
        do {
            try await _Concurrency.Task.detached { try cdr.setDaemon(running: running, using: command) }.value
        } catch {
            commandError = (error as? CDRCommandError)?.description ?? errorText(error)
        }
        await refresh(cdr)
        pendingRunning = nil
    }
}

struct ReviewsPageRow: Identifiable, Equatable {
    let id: String
    let title: String
    let details: String
    /// A queue entry's last error, on its own line.
    var note: String?
    var url: URL?
}

struct ReviewsPageSection: Identifiable, Equatable {
    let title: String
    var rows: [ReviewsPageRow] = []
    var emptyText = ""
    /// Shown instead of rows when the section's source could not be read.
    var message: String?

    var id: String { title }
}

/// Grouping and wording follow CDR's own pages (`renderIndex` and the status queue in its `server/render.mjs`).
enum ReviewsPage {
    static func sections(_ snapshot: CDRSnapshot?) -> [ReviewsPageSection] {
        guard let snapshot else { return [ReviewsPageSection(title: "Running", emptyText: "Reading CDR…")] }
        let reviewServer: URL? = if case .available(let list) = snapshot.reviews { list.baseURL } else { nil }
        return daemonSections(snapshot.daemon, reviewServer: reviewServer) + [recentSection(snapshot.reviews)]
    }

    private static func daemonSections(_ daemon: CDRDaemonState, reviewServer: URL?) -> [ReviewsPageSection] {
        let polling: CDRPolling
        switch daemon {
        case .notInstalled:
            return [ReviewsPageSection(title: "Running", emptyText: "CDR is not installed.")]
        case .stopped:
            return [ReviewsPageSection(title: "Running", emptyText: "The CDR daemon is stopped, so nothing is reviewed or queued.")]
        case .unreachable:
            return [ReviewsPageSection(title: "Running", emptyText: "The CDR daemon is not answering, so its queue is unknown.")]
        case .running(let status):
            guard let found = status.polling else {
                return [ReviewsPageSection(title: "Running", emptyText: "CDR has not polled yet.")]
            }
            polling = found
        }
        func rows(_ entries: [CDRQueueEntry], _ state: String, details: (CDRQueueEntry) -> [String?]) -> [ReviewsPageRow] {
            entries.enumerated().map { index, entry in
                ReviewsPageRow(
                    id: "\(state)-\(entry.request.map(String.init) ?? "#\(index)")",
                    title: entry.title ?? prName(entry),
                    details: ([prName(entry)] + details(entry)).compactMap { $0 }.joined(separator: " · "),
                    note: state == "running" ? nil : entry.lastError.map { "Last error: \($0)" },
                    url: pageURL(entry, reviewServer: reviewServer)
                )
            }
        }
        let running = ReviewsPageSection(
            title: "Running",
            rows: rows(polling.running, "running") { [time("started", $0.startedAt), $0.phase] },
            emptyText: "Nothing is running."
        )
        let queue = [
            ReviewsPageSection(title: "Queued — due, not started", rows: rows(polling.queued, "queued") {
                [time("due", $0.dueAt), $0.blockedBy.map { "held by \(heldBy($0))" }, attempts($0)]
            }),
            ReviewsPageSection(title: "Waiting out the delay", rows: rows(polling.waiting, "waiting") {
                [time("due", $0.dueAt), time("requested", $0.requestedAt)]
            }),
            ReviewsPageSection(title: "Retrying", rows: rows(polling.retrying, "retrying") {
                [attempts($0), time("retry", $0.retryAt)]
            }),
            ReviewsPageSection(title: "Parked", rows: rows(polling.parked, "parked") { [attempts($0)] }),
        ]
        return [running] + queue.filter { !$0.rows.isEmpty }
    }

    private static func recentSection(_ reviews: CDRReviewsState) -> ReviewsPageSection {
        var section = ReviewsPageSection(title: "Recent reviews", emptyText: "CDR has not reviewed anything yet.")
        switch reviews {
        case .serverNotRunning:
            section.message = "CDR's review server is not running, so recent reviews can't be read."
        case .failed(let reason):
            section.message = reason
        case .available(let list):
            section.rows = list.recent.enumerated().map { index, recent in
                let target = recent.target
                let review = recent.review
                let name = "\(target.owner ?? "?")/\(target.repo ?? "?") #\(target.pr.map(String.init) ?? "?")"
                var parts = [name, review.verdict ?? (review.finishedAt == nil ? "still running" : "no verdict")]
                if let findings = review.findings { parts.append(findings == 1 ? "1 finding" : "\(findings) findings") }
                if let source = review.source { parts.append(source) }
                if let finished = review.finishedDate { parts.append("finished \(Format.relative(finished))") }
                if let toPost = target.toPost, toPost > 0 { parts.append("\(toPost) to post") }
                return ReviewsPageRow(
                    id: "review-\(review.id.map(String.init) ?? "\(target.id)-\(index)")",
                    title: target.title ?? name,
                    details: parts.joined(separator: " · "),
                    url: list.pageURL(for: target)
                )
            }
        }
        return section
    }

    /// The header's one line: the daemon's state, or what holds its loop and how much room it has.
    static func statusLine(_ daemon: CDRDaemonState?, now: Date = .now) -> String {
        switch daemon {
        case nil: return "Reading CDR…"
        case .notInstalled: return "CDR is not installed."
        case .stopped: return "Stopped."
        case .unreachable(let reason): return reason
        case .running(let status):
            guard let polling = status.polling else { return "Running." }
            var parts: [String] = []
            if let pause = polling.paused {
                parts.append(pause.until.flatMap(CDRTime.parse).map { "Paused for a usage limit until \(Format.resetTime($0, now: now))" }
                    ?? "Paused for a usage limit")
            }
            if let hold = polling.power?.hold { parts.append("held by \(heldBy(hold))") }
            if let budget = polling.budget, let used = budget.used, let limit = budget.limit {
                parts.append(budget.exhausted == true ? "budget used up (\(used) of \(limit) in 24h)" : "\(used) of \(limit) reviews in 24h")
            }
            if let concurrency = polling.concurrency, let running = concurrency.running, let limit = concurrency.limit {
                parts.append("\(running) of \(limit) running")
            }
            if polling.paused == nil, let next = polling.nextPollAt.flatMap(CDRTime.parse) {
                parts.append("next poll \(Format.relative(next))")
            }
            return parts.isEmpty ? "Running." : parts.joined(separator: " · ")
        }
    }

    /// CDR's `HELD_BY` in `watcher/status.mjs`, without the figures it reads from elsewhere in the status.
    static func heldBy(_ reason: String) -> String {
        switch reason {
        case "concurrency": "the concurrency cap"
        case "budget": "the 24h budget"
        case "runner": "the runner"
        case "poll": "no recent successful poll"
        case "pause": "the usage-limit pause"
        case "battery": "the power source (AC only)"
        case "charge": "the battery charge floor"
        default: reason
        }
    }

    private static func prName(_ entry: CDRQueueEntry) -> String {
        "\(entry.repo ?? "?") #\(entry.pr.map(String.init) ?? "?")"
    }

    private static func time(_ label: String, _ text: String?) -> String? {
        text.flatMap(CDRTime.parse).map { "\(label) \(Format.relative($0))" }
    }

    private static func attempts(_ entry: CDRQueueEntry) -> String? {
        guard let attempts = entry.attempts, attempts > 0 else { return nil }
        return attempts == 1 ? "1 attempt" : "\(attempts) attempts"
    }

    /// CDR's `/pr/<owner>/<repo>/<n>` page while the review server answers, else the PR on GitHub.
    private static func pageURL(_ entry: CDRQueueEntry, reviewServer: URL?) -> URL? {
        if let reviewServer, let repo = entry.repo, let pr = entry.pr {
            return reviewServer.appendingPathComponent("pr/\(repo)/\(pr)")
        }
        return entry.url.flatMap(URL.init(string:))
    }
}

/// Laid out like `PullRequestRow`: the title as a link, the details under it in caption.
struct ReviewsRow: View {
    let row: ReviewsPageRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(row.title, action: open)
                .buttonStyle(.link)
                .disabled(row.url == nil)
                .help(row.url?.absoluteString ?? "")
            Text(row.details)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let note = row.note {
                Text(note)
                    .font(.caption)
                    .lineLimit(4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }

    private func open() {
        if let url = row.url { NSWorkspace.shared.open(url) }
    }
}
