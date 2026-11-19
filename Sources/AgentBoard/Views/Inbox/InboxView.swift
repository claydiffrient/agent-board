import AgentBoardCore
import SwiftUI

/// SPEC §10, Inbox: every question waiting on the human, across projects, answered in place.
struct InboxView: View {
    let projects: [Project]
    let workspaces: [Workspace]

    @Environment(AppEnvironment.self) private var env
    @State private var items = Observed<[InboxItem]>([])
    @State private var projectFilter: String?

    /// Projects in sidebar order, each with its rows oldest asking first.
    static func sections(
        _ items: [InboxItem], projects: [Project], workspaces: [Workspace], filter: String?
    ) -> [(project: Project, items: [InboxItem])] {
        let ordered = ProjectGrouping.sections(projects: projects, workspaces: workspaces).flatMap(\.projects)
        let byProject = Dictionary(grouping: items, by: \.projectId)
        return ordered.compactMap { project in
            guard filter == nil || filter == project.id, let rows = byProject[project.id], !rows.isEmpty else {
                return nil
            }
            return (project, rows.sorted { ($0.questionAt, $0.id) < ($1.questionAt, $1.id) })
        }
    }

    var body: some View {
        let sections = Self.sections(items.value, projects: projects, workspaces: workspaces, filter: projectFilter)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(Self.headline(items.value.count))
                        .font(.title2)
                        .fontWeight(.medium)
                    Spacer()
                    Picker("Project", selection: $projectFilter) {
                        Text("All projects").tag(String?.none)
                        ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .fixedSize()
                }
                if sections.isEmpty {
                    Text(projectFilter == nil ? "No agent is waiting on you." : "Nothing in this project is waiting on you.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sections, id: \.project.id) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.project.name)
                            .font(.headline)
                        ForEach(section.items) { item in
                            InboxRow(item: item)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("Inbox")
        .task {
            await items.run(InboxStore(env.db).observe(), in: env.db.reader)
        }
    }

    static func headline(_ count: Int) -> String {
        switch count {
        case 0: "Nothing is waiting on you."
        case 1: "1 question for you"
        default: "\(count) questions for you"
        }
    }
}

struct InboxRow: View {
    static let caption = "Recorded as your ruling. Nothing is pushed, posted, merged, accepted or closed."

    let item: InboxItem

    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @State private var context = InboxRowContext()
    @State private var note = ""
    @State private var busy = false
    @State private var confirming: InboxAction?
    @State private var errorMessage: String?

    init(item: InboxItem, context: InboxRowContext = InboxRowContext()) {
        self.item = item
        _context = State(initialValue: context)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let question = item.question?.nilIfBlank {
                QuotedText(text: question)
            }
            ForEach(context.standing) { ruling in
                RulingChip(ruling: ruling)
            }
            answerZone
            Divider()
            actZone
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .task(id: item.id) {
            context = (try? InboxRowContext.load(env.db, item: item)) ?? context
        }
        .confirmationDialog(
            confirming?.confirmation ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { action in
            Button(action.confirmButton, role: action.destructive ? .destructive : nil) { perform(action) }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            if let detail = action.detail { Text(detail) }
        }
        .errorAlert($errorMessage)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(subjectTitle)
                .fontWeight(.medium)
                .lineLimit(2)
            Text("\(item.kind.label) · asked by \(asker) \(Format.relative(item.questionAt.asDate))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Answer

    private var answerZone: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Answer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            let verdicts = context.verdicts(for: item)
            let findings = item.kind == .humanReview ? context.findings : []
            if verdicts.isEmpty && findings.isEmpty {
                Text(noVerdictReason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                if !verdicts.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack { verdictButtons(verdicts) }
                        VStack(alignment: .leading) { verdictButtons(verdicts) }
                    }
                }
                ForEach(findings, id: \.number) { finding in
                    findingRow(finding.number, finding.text)
                }
                TextField("Note", text: $note, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Text(Self.caption)
                    .font(.callout)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Answer")
    }

    private func verdictButtons(_ verdicts: [InboxVerdict]) -> some View {
        ForEach(verdicts) { verdict in
            verdictButton(verdict)
        }
    }

    /// Never a default or prominent button: a verdict is chosen, not confirmed with Return.
    private func verdictButton(_ verdict: InboxVerdict) -> some View {
        Button(verdict.title) { answer(verdict) }
            .buttonStyle(.bordered)
            .disabled(busy || (verdict.needsNote && note.nilIfBlank == nil))
            .help(verdict.needsNote ? "\(verdict.help). Needs a note." : verdict.help)
    }

    private func findingRow(_ number: Int, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Finding \(number)")
                .font(.caption.weight(.semibold))
            QuotedText(text: text)
            HStack {
                verdictButton(.overrule(finding: number))
                verdictButton(.uphold(finding: number))
                if let ruling = context.findingRulings[number] {
                    RulingChip(ruling: ruling)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Finding \(number)")
    }

    private var noVerdictReason: String {
        switch item.kind {
        case .blockedTask: "A Claude Code prompt: only the terminal can answer it. Attach below."
        case .proposal: "A proposal takes no ruling: promote or dismiss it below."
        default: "No verdict to give here: accept or reopen it below."
        }
    }

    private func answer(_ verdict: InboxVerdict) {
        guard !busy else { return }
        busy = true
        let text = note
        _Concurrency.Task {
            defer { busy = false }
            do {
                try await InboxAnswering(db: env.db, supervisor: env.supervisor)
                    .answer(verdict, to: item, context: context, note: text)
                note = ""
                context = (try? InboxRowContext.load(env.db, item: item)) ?? context
            } catch {
                errorMessage = errorText(error)
            }
        }
    }

    // MARK: Act

    private var actZone: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Actions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { actionButtons }
                VStack(alignment: .leading) { actionButtons }
            }
        }
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions")
    }

    @ViewBuilder private var actionButtons: some View {
        if let session = context.session, item.kind != .proposal {
            Button("Attach to \(session.displayShortId)") {
                openWindow(id: "terminal", value: session.sessionId)
            }
            .help("Open this agent's Claude session in a terminal window")
        }
        ForEach(actions) { action in
            Button(action.label) { confirming = action }
                .disabled(busy || (action.needsNote && note.nilIfBlank == nil))
                .help(action.needsNote ? "Uses the note above" : action.label)
        }
    }

    private var actions: [InboxAction] {
        InboxAction.offered(for: item, context: context, note: note, supervisor: env.supervisor, db: env.db)
    }

    private func perform(_ action: InboxAction) {
        busy = true
        _Concurrency.Task {
            defer { busy = false }
            do {
                try await action.run()
                if action.needsNote { note = "" }
            } catch {
                errorMessage = errorText(error)
            }
        }
    }

    private var subjectTitle: String {
        switch item.kind {
        case .approval: context.approval.map { InboxAction.describe($0, task: context.task) } ?? item.title
        default: item.title
        }
    }

    private var asker: String {
        switch item.kind {
        case .approval: context.approval?.requestedBy.prefix(8).description ?? "the orchestrator"
        case .blockedTask: item.blockedSource == .prompt ? "Claude Code" : "the worker"
        case .humanReview: "the board"
        case .reviewerStopped: "the reviewer"
        case .proposal: "a worker"
        case .prDecision: "triage"
        case .parkedWatch: "follow-through"
        }
    }
}

extension InboxItemKind {
    var label: String {
        switch self {
        case .approval: "Approval"
        case .blockedTask: "Blocked"
        case .humanReview: "Review"
        case .reviewerStopped: "Reviewer stopped"
        case .proposal: "Proposal"
        case .prDecision: "Pull request decision"
        case .parkedWatch: "Parked pull request"
        }
    }
}

/// An agent's words, set apart as quoted data rather than as the app's own text.
struct QuotedText: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(.tertiary)
                .frame(width: 3)
            Text(verbatim: text)
                .italic()
                .textSelection(.enabled)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Quoted: \(text)")
    }
}

/// "Ruled: hold — <note>", on the Inbox and on every surface the ruled question also shows on.
struct RulingChip: View {
    let ruling: Ruling

    static func text(_ ruling: Ruling) -> String {
        var verdict = ruling.verdict.rawValue.replacingOccurrences(of: "_", with: " ")
        if let choice = ruling.choice { verdict += " (\(choice))" }
        guard let note = ruling.note else { return "Ruled: \(verdict)" }
        return "Ruled: \(verdict) — \(note)"
    }

    var body: some View {
        Text(Self.text(ruling))
            .font(.caption)
            .lineLimit(2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.12), in: Capsule())
            .help("Your ruling, \(Format.relative(ruling.answeredAt.asDate))")
    }
}

/// The newest standing ruling on `subject` that answers the asking stamped `since`, if any.
struct StandingRulingChip: View {
    let subject: RulingSubject
    var since: Int64 = 0

    @Environment(AppEnvironment.self) private var env
    @State private var rulings = Observed<[Ruling]>([])

    var body: some View {
        Group {
            if let ruling = rulings.value.first(where: { $0.questionAt >= since }) {
                RulingChip(ruling: ruling)
            }
        }
        .task(id: subject) {
            await rulings.run(RulingStore(env.db).observeStanding(subject), in: env.db.reader)
        }
    }
}
