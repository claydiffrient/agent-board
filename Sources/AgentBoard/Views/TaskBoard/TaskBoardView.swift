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
    @State private var drafts = TaskDraftCache()
    @State private var collapseChoices: [String: Bool] = [:]
    @State private var showArchived = false
    @State private var confirmArchive = false

    private let columnWidth: CGFloat = 250
    private let jumpRailWidth: CGFloat = 190
    private let collapseStore = EpicCollapseStore()

    private struct Lane: Identifiable {
        let id: String
        let title: String
        let epic: Epic?
        let tasks: [BoardTask]

        func tasks(in column: TaskColumn) -> [BoardTask] {
            tasks.filter { $0.column == column }
        }
    }

    private var partition: ArchivePartition {
        TaskArchive.partition(tasks.value, showArchived: showArchived)
    }

    private var visibleTasks: [BoardTask] {
        partition.visible
    }

    /// Archived tasks the board is not drawing, per lane and column, so a cell can say so rather
    /// than letting the work disappear silently. Keyed by column too, because unarchiving is allowed
    /// from anywhere and an archived task can be moved back out of `done`.
    private var hiddenByEpicAndColumn: [Key: Int] {
        partition.hidden.reduce(into: [:]) { counts, task in
            counts[Key(epicId: task.epicId, column: task.column), default: 0] += 1
        }
    }

    private struct Key: Hashable {
        let epicId: String?
        let column: TaskColumn
    }

    private var archivableTasks: [BoardTask] {
        TaskArchive.archivable(tasks.value)
    }

    private var lanes: [Lane] {
        var byEpic: [String?: [BoardTask]] = [:]
        for task in visibleTasks {
            byEpic[task.epicId, default: []].append(task)
        }
        var result = [Lane(id: EpicLaneOrder.noEpicLaneId, title: "No epic", epic: nil, tasks: byEpic[nil] ?? [])]
        for epic in EpicLaneOrder.sorted(epics.value) {
            result.append(Lane(id: epic.id, title: epic.title, epic: epic, tasks: byEpic[epic.id] ?? []))
        }
        return result
    }

    private var epicLanes: [Lane] { lanes.filter { $0.epic != nil } }

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
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                if !epicLanes.isEmpty {
                    epicJumpRail(proxy)
                    Divider()
                }
                board
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

    private var board: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                columnHeaders
                    .padding(.horizontal)
                    .padding(.top, 12)
                Divider()
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(lanes) { lane in
                            laneView(lane)
                        }
                    }
                    .padding()
                    .contentShape(Rectangle())
                    .onTapGesture { selectedTaskId = nil }
                }
            }
        }
    }

    private func epicJumpRail(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Epics")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    Button("No epic") {
                        withAnimation { proxy.scrollTo(EpicLaneOrder.noEpicLaneId, anchor: .top) }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    ForEach(epicLanes) { lane in
                        if let epic = lane.epic {
                            jumpRailEntry(epic: epic, lane: lane, proxy: proxy)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(width: jumpRailWidth)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func jumpRailEntry(epic: Epic, lane: Lane, proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation { proxy.scrollTo(lane.id, anchor: .top) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(epic.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    EpicStateBadge(state: epic.state)
                    Text(EpicLane.taskCount(columns: lane.tasks.lazy.map(\.column)).label)
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

    private var columnHeaders: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(TaskColumn.allCases, id: \.self) { column in
                columnHeader(column, count: visibleTasks.filter { $0.column == column }.count)
            }
        }
    }

    @ViewBuilder
    private func columnHeader(_ column: TaskColumn, count: Int) -> some View {
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
            if let notice = TaskArchive.hiddenNotice(count: partition.hidden.count { $0.column == column }) {
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
    private func laneView(_ lane: Lane) -> some View {
        let collapsed = lane.epic.map(isCollapsed) ?? false
        VStack(alignment: .leading, spacing: 8) {
            if let epic = lane.epic {
                EpicLaneHeader(
                    epic: epic,
                    count: EpicLane.taskCount(columns: lane.tasks.lazy.map(\.column)),
                    integrationPending: epicsAwaitingIntegrationApproval.contains(epic.id),
                    isCollapsed: collapsed,
                    onToggleCollapse: { toggleCollapse(epic) },
                    onRequestIntegration: { requestIntegration(epic) },
                    onOpenPullRequest: { openPullRequest(epic) }
                )
            } else if lanes.count > 1 {
                Text(lane.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if !collapsed {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(TaskColumn.allCases, id: \.self) { column in
                        columnCell(lane: lane, column: column)
                    }
                }
            }
        }
        .id(lane.id)
    }

    private func columnCell(lane: Lane, column: TaskColumn) -> some View {
        VStack(spacing: 8) {
            let hidden = hiddenByEpicAndColumn[Key(epicId: lane.epic?.id, column: column)] ?? 0
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
