import AgentBoardCore
import GRDB
import SwiftUI

struct TaskBoardView: View {
    let project: Project

    @Environment(AppEnvironment.self) private var env
    @State private var tasks = Observed<[BoardTask]>([])
    @State private var sessions = Observed<[AgentSession]>([])
    @State private var epics = Observed<[Epic]>([])
    @State private var selectedTaskId: String?
    @State private var showNewTask = false
    @State private var showNewEpic = false
    @State private var approvals = Observed<[Approval]>([])
    @State private var busyMessage: String?
    @State private var errorMessage: String?
    @State private var taskPendingDelete: BoardTask?
    @State private var closurePlan: EpicClosurePlan?
    @State private var drafts = TaskDraftCache()
    @State private var collapseChoices: [String: Bool] = [:]
    @State private var showArchived = false
    @State private var confirmArchive = false
    @State private var jumpTarget: String?
    @State private var query = ""
    @State private var rosterAgents = Observed<[RosterAgent]>([])
    @State private var searchIndex = TaskSearch.IndexCache()

    private let columnWidth: CGFloat = 250
    private let jumpRailWidth: CGFloat = 190
    private let collapseStore = EpicCollapseStore()

    private struct Lane: Identifiable {
        let id: String
        let title: String
        let epic: Epic?
        /// The cards this lane draws, narrowed by the query.
        let tasks: [BoardTask]
        /// The whole lane's tally, so a query never changes what the header offers.
        let count: EpicTaskCount

        func tasks(in column: TaskColumn) -> [BoardTask] {
            tasks.filter { $0.column == column }
        }
    }

    private var partition: ArchivePartition {
        TaskArchive.partition(tasks.value, showArchived: showArchived)
    }

    /// What the archive toggle lets through, before the query. Selection, the inspector and drops
    /// work over this, so typing never closes the inspector on the task being edited.
    private var visibleTasks: [BoardTask] {
        partition.visible
    }

    private var searchQuery: SearchQuery { SearchQuery(query) }

    private var agentNames: [String: String] {
        Dictionary(rosterAgents.value.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// Computed once per body and passed down: every lane, rail entry and header reads it, and a
    /// query re-runs the match over every task each time it is recomputed.
    private struct Layout {
        let lanes: [Lane]
        let searched: ArchivePartition
        let isSearching: Bool

        /// Archived tasks the board is not drawing, per lane and column, so a cell can say so rather
        /// than letting the work disappear silently. Keyed by column too, because unarchiving is
        /// allowed from anywhere and an archived task can be moved back out of `done`.
        let hiddenByEpicAndColumn: [Key: Int]

        var lanesById: [String: Lane] {
            Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, $0) })
        }
    }

    private struct Key: Hashable {
        let epicId: String?
        let column: TaskColumn
    }

    private var archivableTasks: [BoardTask] {
        TaskArchive.archivable(tasks.value)
    }

    /// While a query is active a lane with nothing matching vanishes, header and all, unless it is
    /// hiding an archived match: then it stays so its cell can say where that match is.
    private var layout: Layout {
        let partition = partition
        let isSearching = !searchQuery.isEmpty
        let searched = isSearching
            ? TaskSearch.narrow(partition, query: searchQuery, index: searchIndex.index(
                tasks.value, epicTitles: epicTitles, agentNames: agentNames
            ))
            : partition
        let hidden = searched.hidden.reduce(into: [Key: Int]()) { counts, task in
            counts[Key(epicId: task.epicId, column: task.column), default: 0] += 1
        }
        let all = Dictionary(grouping: partition.visible, by: \.epicId)
        let shown = Dictionary(grouping: searched.visible, by: \.epicId)
        let hiding = Set(searched.hidden.map(\.epicId))
        func lane(id: String, title: String, epic: Epic?) -> Lane {
            Lane(
                id: id, title: title, epic: epic, tasks: shown[epic?.id] ?? [],
                count: EpicLane.taskCount(columns: (all[epic?.id] ?? []).lazy.map(\.column))
            )
        }
        var lanes = [lane(id: EpicLaneOrder.noEpicLaneId, title: EpicJumpRail.noEpicTitle, epic: nil)]
        for epic in EpicLaneOrder.sorted(epics.value) {
            lanes.append(lane(id: epic.id, title: epic.title, epic: epic))
        }
        if isSearching {
            lanes.removeAll { $0.tasks.isEmpty && !hiding.contains($0.epic?.id) }
        }
        return Layout(lanes: lanes, searched: searched, isSearching: isSearching, hiddenByEpicAndColumn: hidden)
    }

    private func isCollapsed(_ epic: Epic) -> Bool {
        EpicLaneCollapse.isCollapsed(
            state: epic.state,
            userChoice: collapseChoices[epic.id] ?? collapseStore.userChoice(epicId: epic.id)
        )
    }

    private func toggleCollapse(_ epic: Epic) {
        let collapsed = !isCollapsed(epic)
        collapseChoices[epic.id] = collapsed
        collapseStore.setUserChoice(collapsed, epicId: epic.id)
    }

    private var sessionsByTask: [String: [AgentSession]] {
        var result: [String: [AgentSession]] = [:]
        for session in sessions.value {
            guard let taskId = session.taskId else { continue }
            result[taskId, default: []].append(session)
        }
        return result
    }

    private var epicsAwaitingIntegrationApproval: Set<String> {
        Set(approvals.value.filter { $0.kind == .integration }.compactMap(\.epicId))
    }

    private var epicTitles: [String: String] {
        Dictionary(uniqueKeysWithValues: epics.value.map { ($0.id, $0.title) })
    }

    var body: some View {
        let layout = layout
        VStack(spacing: 0) {
            SearchField(
                noun: .tasks, text: $query, shown: layout.searched.visible.count, total: visibleTasks.count,
                note: showArchived ? nil : TaskSearch.hiddenMatchesNote(count: layout.searched.hidden.count)
            )
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            HStack(spacing: 0) {
                if !epics.value.isEmpty {
                    epicJumpRail(layout)
                    Divider()
                }
                board(layout)
            }
        }
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { selectedTaskId = nil }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { selectedTaskId = nil }
        .onChange(of: visibleTasks) { _, updated in
            let reconciled = TaskSelection.reconciled(current: selectedTaskId, availableIds: updated.lazy.map(\.id))
            if reconciled != selectedTaskId { selectedTaskId = reconciled }
        }
        .task(id: project.id) {
            await tasks.run(TaskStore(env.db).observe(projectId: project.id, includeArchived: true), in: env.db.reader)
        }
        .task(id: project.id) {
            await sessions.run(SessionStore(env.db).observe(projectId: project.id), in: env.db.reader)
        }
        .task(id: project.id) {
            let projectId = project.id
            let observation = ValueObservation.tracking { db -> [Epic] in
                try Epic.fetchAll(
                    db,
                    sql: "SELECT * FROM epic WHERE project_id = ? ORDER BY created_at",
                    arguments: [projectId]
                )
            }
            await epics.run(observation, in: env.db.reader)
        }
        .task(id: project.id) {
            await approvals.run(ApprovalStore(env.db).observePending(projectId: project.id), in: env.db.reader)
        }
        .task {
            await rosterAgents.run(RosterStore(env.db).observe(), in: env.db.reader)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showNewEpic = true
                } label: {
                    Label("New Epic", systemImage: "square.stack.3d.up")
                }
                .help("Create an epic and its initial tasks")
            }
            ToolbarItem {
                Button {
                    showNewTask = true
                } label: {
                    Label("New Task", systemImage: "plus")
                }
                .help("Create a task")
            }
            ToolbarItem {
                Button {
                    confirmArchive = true
                } label: {
                    Label(TaskArchive.buttonTitle(count: archivableTasks.count), systemImage: "archivebox")
                }
                .disabled(archivableTasks.isEmpty)
                .help("Hide every done task from the board. Nothing is deleted.")
            }
            ToolbarItem {
                Toggle(isOn: $showArchived) {
                    Label("Show Archived", systemImage: showArchived ? "eye" : "eye.slash")
                }
                .help("Draw archived tasks back into their columns, dimmed and labelled")
            }
        }
        .sheet(isPresented: $showNewTask) {
            NewTaskSheet(projectId: project.id)
        }
        .sheet(isPresented: $showNewEpic) {
            NewEpicSheet(projectId: project.id)
        }
        .inspector(isPresented: inspectorShown) {
            if let task = visibleTasks.first(where: { $0.id == selectedTaskId }) {
                TaskInspectorView(
                    task: task,
                    allTasks: visibleTasks,
                    sessions: sessionsByTask[task.id] ?? [],
                    drafts: drafts,
                    onClose: { selectedTaskId = nil }
                )
                .inspectorColumnWidth(min: 300, ideal: 360)
            }
        }
        .background(deleteConfirmation)
        .background(archiveConfirmation)
        .background(closeEpicConfirmation)
        .overlay {
            if let busyMessage {
                ZStack {
                    Color.black.opacity(0.15)
                    ProgressView(busyMessage)
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .errorAlert($errorMessage)
    }

    private func board(_ layout: Layout) -> some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                columnHeaders(layout)
                    .padding(.horizontal)
                    .padding(.top, 12)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(layout.lanes) { lane in
                                laneView(lane, in: layout)
                            }
                        }
                        .padding()
                        .contentShape(Rectangle())
                        .onTapGesture { selectedTaskId = nil }
                    }
                    .onChange(of: jumpTarget) { _, target in
                        guard let target else { return }
                        withAnimation { proxy.scrollTo(target, anchor: .top) }
                        jumpTarget = nil
                    }
                }
            }
        }
    }

    private func epicJumpRail(_ layout: Layout) -> some View {
        let lanesById = layout.lanesById
        return VStack(alignment: .leading, spacing: 0) {
            Text("Epics")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(EpicJumpRail.entries(epics.value).filter { lanesById[$0.laneId] != nil }) { entry in
                        if let lane = lanesById[entry.laneId], let epic = lane.epic {
                            jumpRailEntry(epic: epic, lane: lane)
                        } else {
                            Button(entry.title) { jumpTarget = entry.laneId }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(width: jumpRailWidth)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func jumpRailEntry(epic: Epic, lane: Lane) -> some View {
        Button {
            jumpTarget = EpicJumpRail.laneId(forEpicId: epic.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(epic.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    EpicStateBadge(state: epic.state)
                    Text(lane.count.label)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Scroll to \(epic.title)")
    }

    private var inspectorShown: Binding<Bool> {
        Binding(
            get: { selectedTaskId != nil },
            set: { if !$0 { selectedTaskId = nil } }
        )
    }

    private func columnHeaders(_ layout: Layout) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(TaskColumn.allCases, id: \.self) { column in
                columnHeader(
                    column,
                    count: layout.searched.visible.count { $0.column == column },
                    hidden: layout.searched.hidden.count { $0.column == column }
                )
            }
        }
    }

    @ViewBuilder
    private func columnHeader(_ column: TaskColumn, count: Int, hidden: Int) -> some View {
        let header = HStack(spacing: 6) {
            Text(column.title)
                .font(.headline)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.2)))
            if column == .ready {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            if let notice = TaskArchive.hiddenNotice(count: hidden) {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Hidden from the board, not deleted. Turn on Show Archived to see them.")
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(width: columnWidth + 16)
        .padding(.bottom, 8)

        if column == .ready {
            header.help("Ready is the only column the orchestrator may pull from.")
        } else {
            header
        }
    }

    @ViewBuilder
    private func laneView(_ lane: Lane, in layout: Layout) -> some View {
        let collapsed = !layout.isSearching && (lane.epic.map(isCollapsed) ?? false)
        VStack(alignment: .leading, spacing: 8) {
            if let epic = lane.epic {
                EpicLaneHeader(
                    epic: epic,
                    count: lane.count,
                    integrationPending: epicsAwaitingIntegrationApproval.contains(epic.id),
                    isCollapsed: collapsed,
                    onToggleCollapse: { toggleCollapse(epic) },
                    onRequestIntegration: { requestIntegration(epic) },
                    onOpenPullRequest: { openPullRequest(epic) },
                    onClose: { planClosure(epic, as: $0) }
                )
            } else if layout.lanes.count > 1 {
                Text(lane.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if !collapsed {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(TaskColumn.allCases, id: \.self) { column in
                        columnCell(lane: lane, column: column, hidden: layout.hiddenByEpicAndColumn)
                    }
                }
            }
        }
        .id(lane.id)
    }

    private func columnCell(lane: Lane, column: TaskColumn, hidden: [Key: Int]) -> some View {
        VStack(spacing: 8) {
            let hidden = hidden[Key(epicId: lane.epic?.id, column: column)] ?? 0
            if let notice = TaskArchive.hiddenNotice(count: hidden) {
                HStack(spacing: 4) {
                    Image(systemName: "archivebox")
                    Text(notice)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Hidden from the board, not deleted. Turn on Show Archived to see them.")
            }
            ForEach(lane.tasks(in: column)) { task in
                let taskSessions = sessionsByTask[task.id] ?? []
                TaskCardView(
                    task: task,
                    epicTitle: task.epicId.flatMap { epicTitles[$0] },
                    activeSession: taskSessions.first { $0.state.isActive },
                    latestSession: taskSessions.first,
                    isSelected: task.id == selectedTaskId,
                    onAccept: { accept(task.id) },
                    onReopen: { reopen(task.id) }
                )
                .draggable(task.id)
                .onTapGesture { selectedTaskId = TaskSelection.toggled(current: selectedTaskId, tapped: task.id) }
                .contextMenu {
                    Button("Details") { selectedTaskId = task.id }
                    Menu("Move to") {
                        ForEach(TaskColumn.allCases.filter { $0 != task.column }, id: \.self) { target in
                            Button(target.title) { _ = drop(taskId: task.id, onto: target) }
                        }
                    }
                    Divider()
                    if task.isArchived {
                        Button("Unarchive") { unarchive(task.id) }
                    } else if task.column == .done {
                        Button("Archive") { archive([task.id]) }
                    }
                    Button("Delete Task…", role: .destructive) { taskPendingDelete = task }
                }
            }
        }
        .frame(width: columnWidth)
        .frame(minHeight: 140, alignment: .top)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .underPageBackgroundColor))
        )
        .dropDestination(for: String.self) { ids, _ in
            var accepted = false
            for id in ids {
                accepted = drop(taskId: id, onto: column) || accepted
            }
            return accepted
        }
    }

    private func drop(taskId: String, onto column: TaskColumn) -> Bool {
        guard let task = visibleTasks.first(where: { $0.id == taskId }), task.column != column else {
            return false
        }
        switch column {
        case .running:
            assign(taskId)
        case .done where task.column == .review:
            accept(taskId)
        default:
            do {
                try TaskStore(env.db).move(taskId, to: column)
            } catch {
                errorMessage = errorText(error)
            }
        }
        return true
    }

    private func requestIntegration(_ epic: Epic) {
        runSupervised("Requesting integration…") { try await env.supervisor.requestIntegration(epicId: epic.id) }
    }

    private func openPullRequest(_ epic: Epic) {
        runSupervised("Opening pull request page…") {
            _ = try await env.supervisor.openPullRequest(epicId: epic.id)
        }
    }

    private func assign(_ taskId: String) {
        runSupervised("Spawning worker…") { try await env.supervisor.assign(taskId: taskId) }
    }

    private var deleteConfirmation: some View {
        EmptyView()
            .confirmationDialog(
                "Delete \"\(taskPendingDelete?.title ?? "")\"?",
                isPresented: Binding(get: { taskPendingDelete != nil }, set: { if !$0 { taskPendingDelete = nil } }),
                presenting: taskPendingDelete
            ) { task in
                Button("Delete", role: .destructive) {
                    if selectedTaskId == task.id { selectedTaskId = nil }
                    runSupervised("Deleting…") { try await env.supervisor.discard(taskId: task.id) }
                }
            } message: { _ in
                Text("Stops any running worker and removes its worktree. The branch is kept.")
            }
    }

    private var archiveConfirmation: some View {
        EmptyView()
            .confirmationDialog(
                TaskArchive.confirmationTitle(count: archivableTasks.count),
                isPresented: $confirmArchive,
                titleVisibility: .visible
            ) {
                Button("Archive") { archive(archivableTasks.map(\.id)) }
            } message: {
                Text("They leave the board but are never deleted — branches, worktrees and reports are untouched. Turn on Show Archived to bring them back into view, or unarchive one from its card.")
            }
    }

    /// The plan is read before the dialog opens, so its copy names this epic's actual leftovers and
    /// its actual running workers rather than describing closing in general.
    private func planClosure(_ epic: Epic, as closure: EpicClosure) {
        do {
            closurePlan = try env.supervisor.epicClosurePlan(epicId: epic.id, as: closure)
        } catch {
            errorMessage = errorText(error)
        }
    }

    private var closeEpicConfirmation: some View {
        EmptyView()
            .confirmationDialog(
                closurePlan?.title ?? "",
                isPresented: Binding(get: { closurePlan != nil }, set: { if !$0 { closurePlan = nil } }),
                titleVisibility: .visible,
                presenting: closurePlan
            ) { plan in
                if !plan.isRefused {
                    Button(plan.closure.confirmLabel, role: .destructive) {
                        runSupervised("Closing epic…") {
                            try await env.supervisor.closeEpic(epicId: plan.epicId, as: plan.closure)
                        }
                    }
                }
            } message: { plan in
                Text(plan.message)
            }
    }

    private func archive(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        do {
            try TaskStore(env.db).archive(ids: ids)
        } catch {
            errorMessage = errorText(error)
        }
    }

    private func unarchive(_ taskId: String) {
        do {
            try TaskStore(env.db).unarchive(taskId)
        } catch {
            errorMessage = errorText(error)
        }
    }

    private func accept(_ taskId: String) {
        runSupervised("Accepting…") { try await env.supervisor.accept(taskId: taskId) }
    }

    private func reopen(_ taskId: String) {
        runSupervised("Reopening…") { try await env.supervisor.reopen(taskId: taskId) }
    }

    private func runSupervised(_ message: String, _ operation: @escaping () async throws -> Void) {
        busyMessage = message
        _Concurrency.Task {
            defer { busyMessage = nil }
            do {
                try await operation()
            } catch {
                errorMessage = errorText(error)
            }
        }
    }
}

#Preview("Task Board") {
    let preview = PreviewData.make()
    TaskBoardView(project: preview.project)
        .environment(preview.environment)
        .frame(width: 1400, height: 700)
}
