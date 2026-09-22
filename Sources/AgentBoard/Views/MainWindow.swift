import AgentBoardCore
import AppKit
import SwiftUI

struct MainWindow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @State private var projects = Observed<[Project]>([])
    @State private var workspaces = Observed<[Workspace]>([])
    @State private var attention = Observed<[ProjectAttention]>([])
    @State private var selection: SidebarSelection = .atAGlance
    @State private var settingsProject: Project?
    @State private var workspaceEdit: WorkspaceEdit?
    @State private var workspaceToDelete: Workspace?
    @State private var collapsed: Set<String>
    @State private var errorMessage: String?
    @State private var usageFooterHeight: CGFloat = 0

    private let collapseState: SidebarCollapseState

    init(collapseState: SidebarCollapseState = .standard) {
        self.collapseState = collapseState
        _collapsed = State(initialValue: collapseState.load())
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            switch selection {
            case .roster:
                RosterView(activity: LiveRosterActivity(db: env.db))
            case .atAGlance, .project:
                if let project = projects.value.first(where: { $0.id == selection.projectId }) {
                    ProjectDetailView(project: project)
                        .id(project.id)
                } else {
                    AtAGlanceView(
                        projects: projects.value, workspaces: workspaces.value,
                        attention: attention.value, select: select
                    )
                }
            }
        }
        .task {
            await projects.run(ProjectStore(env.db).observeAll(), in: env.db.reader)
        }
        .task {
            await workspaces.run(WorkspaceStore(env.db).observe(), in: env.db.reader)
        }
        .task {
            await attention.run(ProjectAttentionStore(env.db).observeAll(), in: env.db.reader)
        }
        .task { await announceReleaseNotes() }
        .sheet(item: $settingsProject) { project in
            ProjectSettingsSheet(project: project, workspaces: workspaces.value) {
                if selection == .project(project.id) { select(.atAGlance) }
            }
        }
        .sheet(item: $workspaceEdit) { edit in
            WorkspaceNameSheet(edit: edit) { name in commit(edit, name: name) }
        }
        .confirmationDialog(
            workspaceToDelete.map { "Delete the \($0.name) workspace?" } ?? "",
            isPresented: Binding(get: { workspaceToDelete != nil }, set: { if !$0 { workspaceToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Workspace", role: .destructive) {
                if let workspace = workspaceToDelete { deleteWorkspace(workspace) }
            }
        } message: {
            Text("Its projects stay in the sidebar and become ungrouped.")
        }
        .errorAlert($errorMessage)
        .onChange(of: env.router.sequence) { openRoutedProject() }
    }

    /// Last in the launch sequence, after `supervisor.start()` returns — the server bind, the
    /// stale-lock sweep and the worktree-root migration all write to the board a human is about to
    /// be shown, and a window over the middle of that hides work still settling. It does not stand
    /// aside for a board that already needs attention; SPEC §10 has the argument.
    private func announceReleaseNotes() async {
        await env.startup?.value
        guard env.releaseNotes.announceOnLaunch() else { return }
        openWindow(id: ReleaseNotesScene.id)
    }

    /// A banner click selects its project through `select`, the same funnel the sidebar uses, so
    /// the orchestrator starts exactly as it does on a click. The screen is `ProjectDetailView`'s.
    private func openRoutedProject() {
        guard let route = env.router.route,
              projects.value.contains(where: { $0.id == route.projectId })
        else { return }
        select(.project(route.projectId))
    }

    private var sections: [ProjectSection] {
        ProjectGrouping.sections(projects: projects.value, workspaces: workspaces.value)
    }

    /// One observation feeds every row and every header. `List` rebuilds a row on any scroll or
    /// selection change, so a row that started its own observation would open and tear one down
    /// per project per rebuild.
    private var attentionById: [String: ProjectAttention] {
        Dictionary(attention.value.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The only writer of `selection`. Adding a project, deselecting in the sidebar, deleting the
    /// open project and clicking an At a Glance card all land here, so no two paths can disagree.
    private func select(_ next: SidebarSelection) {
        selection = next
        env.supervisor.focusChanged(projectId: next.projectId)
    }

    private var sidebarSelection: Binding<SidebarSelection?> {
        Binding(get: { selection }, set: { select($0 ?? .atAGlance) })
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Label("At a Glance", systemImage: "square.grid.2x2")
                .tag(SidebarSelection.atAGlance)
            Label("Roster", systemImage: "person.2")
                .tag(SidebarSelection.roster)
            ForEach(sections) { section in
                sectionView(section)
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                PortsPanel(ceiling: PortsPanel.ceiling(footerHeight: usageFooterHeight))
                HStack(spacing: 4) {
                    Button {
                        addProject()
                    } label: {
                        Label("Add Project…", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    workspaceMenu
                }
                .padding(8)
                NotificationsOffNotice()
                AccountUsageFooter(model: env.accountUsage)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { usageFooterHeight = $0 }
            }
        }
        .overlay {
            if projects.value.isEmpty && workspaces.value.isEmpty {
                Text("No projects yet")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: ProjectSection) -> some View {
        if section.isUngrouped && workspaces.value.isEmpty {
            Section {
                ForEach(section.projects) { projectRow($0) }
            }
        } else {
            Section(isExpanded: expansion(section.id)) {
                ForEach(section.projects) { projectRow($0) }
            } header: {
                sectionHeader(section)
            }
        }
    }

    private func sectionHeader(_ section: ProjectSection) -> some View {
        HStack(spacing: 4) {
            Text(section.workspace?.name ?? "Ungrouped")
            Spacer(minLength: 4)
            // Only while collapsed: expanded, the rows carry their own badges, and a second mark
            // saying the same thing would just be noise.
            if collapsed.contains(section.id),
               let summary = collapsedSectionSummary(section, attention: attentionById) {
                AttentionBadge(reason: summary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { projectIds, _ in
            assign(projectIds, to: section.workspace?.id)
        }
        .contextMenu {
            if let workspace = section.workspace {
                Button("Rename…") { workspaceEdit = .rename(workspace) }
                Button("Delete Workspace…", role: .destructive) { workspaceToDelete = workspace }
            }
        }
    }

    private func projectRow(_ project: Project) -> some View {
        ProjectRow(
            project: project,
            attention: attentionById[project.id],
            openSettings: { settingsProject = project }
        )
        .tag(SidebarSelection.project(project.id))
        .draggable(project.id)
    }

    private var workspaceMenu: some View {
        Menu {
            Button("New Workspace…") { workspaceEdit = .create }
            if !workspaces.value.isEmpty {
                Divider()
                ForEach(workspaces.value) { workspace in
                    Menu(workspace.name) {
                        Button("Rename…") { workspaceEdit = .rename(workspace) }
                        Button("Move Up") { move(workspace, by: -1) }
                            .disabled(workspaces.value.first?.id == workspace.id)
                        Button("Move Down") { move(workspace, by: 1) }
                            .disabled(workspaces.value.last?.id == workspace.id)
                        Divider()
                        Button("Delete Workspace…", role: .destructive) { workspaceToDelete = workspace }
                    }
                }
            }
        } label: {
            Image(systemName: "folder.badge.gearshape")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Workspaces")
    }

    private func expansion(_ sectionId: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(sectionId) },
            set: { expanded in
                if expanded {
                    collapsed.remove(sectionId)
                } else {
                    collapsed.insert(sectionId)
                }
                collapseState.save(collapsed)
            }
        )
    }

    private func assign(_ projectIds: [String], to workspaceId: String?) -> Bool {
        let store = WorkspaceStore(env.db)
        do {
            for id in projectIds {
                try store.assign(projectId: id, workspaceId: workspaceId)
            }
            return !projectIds.isEmpty
        } catch {
            errorMessage = errorText(error)
            return false
        }
    }

    private func commit(_ edit: WorkspaceEdit, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            if let workspace = edit.workspace {
                try WorkspaceStore(env.db).rename(workspace.id, to: trimmed)
            } else {
                try WorkspaceStore(env.db).create(name: trimmed)
            }
        } catch {
            errorMessage = errorText(error)
        }
    }

    private func deleteWorkspace(_ workspace: Workspace) {
        do {
            try WorkspaceStore(env.db).delete(workspace.id)
            collapsed.remove(workspace.id)
            collapseState.save(collapsed)
        } catch {
            errorMessage = errorText(error)
        }
        workspaceToDelete = nil
    }

    private func move(_ workspace: Workspace, by offset: Int) {
        let ordered = workspaces.value
        guard let index = ordered.firstIndex(where: { $0.id == workspace.id }) else { return }
        let target = index + offset
        guard ordered.indices.contains(target) else { return }
        let neighbour = ordered[target]
        do {
            let store = WorkspaceStore(env.db)
            try store.setOrdering(workspace.id, neighbour.ordering)
            try store.setOrdering(neighbour.id, workspace.ordering)
        } catch {
            errorMessage = errorText(error)
        }
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Choose the root of a git repository."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _Concurrency.Task {
            do {
                let project = try await env.supervisor.registerProject(repoPath: url, name: nil, baseBranch: nil)
                select(.project(project.id))
            } catch {
                errorMessage = errorText(error)
            }
        }
    }
}

struct ProjectDetailView: View {
    let project: Project

    @Environment(AppEnvironment.self) private var env

    enum Screen: String, CaseIterable, Identifiable {
        case orchestrator = "Orchestrator"
        case terminal = "Terminal"
        case board = "Task Board"
        case status = "Status"
        case notes = "Notes"

        var id: String { rawValue }
    }

    static let defaultScreen = Screen.orchestrator

    @State private var screen: Screen = ProjectDetailView.defaultScreen

    var body: some View {
        Group {
            switch screen {
            case .board: TaskBoardView(project: project)
            case .status: StatusView(project: project)
            case .notes: NotesView(project: project)
            case .orchestrator: OrchestratorView(project: project)
            case .terminal: TerminalScreenView(project: project)
            }
        }
        .navigationTitle(project.name)
        .task(id: env.router.sequence) {
            if let route = env.router.route, route.projectId == project.id { screen = route.screen }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Screen", selection: $screen) {
                    ForEach(Screen.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}
