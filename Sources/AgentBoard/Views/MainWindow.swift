import AgentBoardCore
import AppKit
import SwiftUI

struct MainWindow: View {
    @Environment(AppEnvironment.self) private var env
    @State private var projects = Observed<[Project]>([])
    @State private var selectedProjectId: String?
    @State private var settingsProject: Project?
    @State private var errorMessage: String?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let project = projects.value.first(where: { $0.id == selectedProjectId }) {
                ProjectDetailView(project: project)
                    .id(project.id)
            } else {
                ContentUnavailableView(
                    "No Project Selected",
                    systemImage: "folder",
                    description: Text("Choose a project in the sidebar or add one.")
                )
            }
        }
        .task {
            await projects.run(ProjectStore(env.db).observeAll(), in: env.db.reader)
        }
        .sheet(item: $settingsProject) { project in
            ProjectSettingsSheet(project: project) {
                if selectedProjectId == project.id { selectedProjectId = nil }
            }
        }
        .errorAlert($errorMessage)
    }

    private var sidebar: some View {
        List(projects.value, selection: $selectedProjectId) { project in
            HStack {
                Label(project.name, systemImage: "folder")
                    .help(project.repoPath)
                Spacer()
                Button {
                    settingsProject = project
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Project settings")
            }
            .tag(project.id)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        .safeAreaInset(edge: .bottom) {
            Button {
                addProject()
            } label: {
                Label("Add Project…", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .padding(8)
        }
        .overlay {
            if projects.value.isEmpty {
                Text("No projects yet")
                    .foregroundStyle(.secondary)
            }
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
                selectedProjectId = project.id
            } catch {
                errorMessage = errorText(error)
            }
        }
    }
}

struct ProjectDetailView: View {
    let project: Project

    private enum Screen: String, CaseIterable, Identifiable {
        case board = "Task Board"
        case status = "Status"
        case notes = "Notes"
        case orchestrator = "Orchestrator"

        var id: String { rawValue }
    }

    @State private var screen: Screen = .board

    var body: some View {
        Group {
            switch screen {
            case .board: TaskBoardView(project: project)
            case .status: StatusView(project: project)
            case .notes: NotesView(project: project)
            case .orchestrator: OrchestratorView(project: project)
            }
        }
        .navigationTitle(project.name)
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
