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
    @State private var busyMessage: String?
    @State private var errorMessage: String?

    private let columnWidth: CGFloat = 250

    private struct Lane: Identifiable {
        let id: String
        let title: String
        let tasks: [BoardTask]

        func tasks(in column: TaskColumn) -> [BoardTask] {
            tasks.filter { $0.column == column }
        }
    }

    private var lanes: [Lane] {
        var byEpic: [String?: [BoardTask]] = [:]
        for task in tasks.value {
            byEpic[task.epicId, default: []].append(task)
        }
        var result = [Lane(id: "no-epic", title: "No epic", tasks: byEpic[nil] ?? [])]
        for epic in epics.value {
            result.append(Lane(id: epic.id, title: epic.title, tasks: byEpic[epic.id] ?? []))
        }
        return result
    }

    private var sessionsByTask: [String: [AgentSession]] {
        var result: [String: [AgentSession]] = [:]
        for session in sessions.value {
            guard let taskId = session.taskId else { continue }
            result[taskId, default: []].append(session)
        }
        return result
    }

    private var epicTitles: [String: String] {
        Dictionary(uniqueKeysWithValues: epics.value.map { ($0.id, $0.title) })
    }

    var body: some View {
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
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: project.id) {
            await tasks.run(TaskStore(env.db).observe(projectId: project.id), in: env.db.reader)
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
        .toolbar {
            ToolbarItem {
                Button {
                    showNewTask = true
                } label: {
                    Label("New Task", systemImage: "plus")
                }
                .help("Create a task")
            }
        }
        .sheet(isPresented: $showNewTask) {
            NewTaskSheet(projectId: project.id)
        }
        .inspector(isPresented: inspectorShown) {
            if let task = tasks.value.first(where: { $0.id == selectedTaskId }) {
                TaskInspectorView(
                    task: task,
                    allTasks: tasks.value,
                    sessions: sessionsByTask[task.id] ?? []
                )
                .inspectorColumnWidth(min: 300, ideal: 360)
            }
        }
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

    private var inspectorShown: Binding<Bool> {
        Binding(
            get: { selectedTaskId != nil },
            set: { if !$0 { selectedTaskId = nil } }
        )
    }

    private var columnHeaders: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(TaskColumn.allCases, id: \.self) { column in
                columnHeader(column, count: tasks.value.filter { $0.column == column }.count)
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
        VStack(alignment: .leading, spacing: 8) {
            if lanes.count > 1 {
                Text(lane.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(TaskColumn.allCases, id: \.self) { column in
                    columnCell(lane: lane, column: column)
                }
            }
        }
    }

    private func columnCell(lane: Lane, column: TaskColumn) -> some View {
        VStack(spacing: 8) {
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
                .onTapGesture { selectedTaskId = task.id }
                .contextMenu {
                    Button("Details") { selectedTaskId = task.id }
                    Menu("Move to") {
                        ForEach(TaskColumn.allCases.filter { $0 != task.column }, id: \.self) { target in
                            Button(target.title) { _ = drop(taskId: task.id, onto: target) }
                        }
                    }
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
        guard let task = tasks.value.first(where: { $0.id == taskId }), task.column != column else {
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

    private func assign(_ taskId: String) {
        runSupervised("Spawning worker…") { try await env.supervisor.assign(taskId: taskId) }
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
