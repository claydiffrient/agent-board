import AgentBoardCore
import AppKit
import SwiftUI

/// What a port row's owner cell says and where clicking it goes. A value rather than a view so the
/// routing can be asserted without a mount.
struct PortOwnerLabel: Equatable {
    let title: String
    let detail: String?
    /// Nil when nothing names the owner. That row's title is not a link because there is nowhere
    /// to send a click.
    let route: NotificationRoute?
    /// No running session behind it: either the parent chain broke and only the pid ledger named
    /// the owner — the dev server whose session ended an hour ago — or nothing names it at all.
    let ended: Bool

    static let orphanTitle = "orphaned"
}

/// Who a listening port belongs to, in the words the sidebar uses.
///
/// A ledger-sourced row keeps its owner: the session is over but `agent_session` and `task` still
/// hold the name, and routing to the project's Status roster is the only way a human reaches it.
func portOwnerLabel(_ port: AttributedPort) -> PortOwnerLabel {
    func orphan() -> PortOwnerLabel {
        PortOwnerLabel(title: PortOwnerLabel.orphanTitle, detail: port.command, route: nil, ended: true)
    }
    let ended = port.ownership == .orphaned

    if let sessionId = port.sessionId, let projectId = port.projectId {
        return PortOwnerLabel(
            title: port.taskTitle ?? "Session \(sessionId.prefix(8))",
            detail: port.projectName,
            route: NotificationRoute(projectId: projectId, subject: .session(sessionId)),
            ended: ended
        )
    }
    guard port.sessionId == nil, let projectId = port.projectId else { return orphan() }
    return PortOwnerLabel(
        title: "Terminal",
        detail: port.projectName,
        route: NotificationRoute(projectId: projectId, subject: .terminal),
        ended: ended
    )
}

/// One listening port: the number, the command holding it, and who it belongs to.
///
/// Two link targets, and they go to different places on purpose — the number opens what the port
/// serves, the owner opens the session that opened it.
struct PortRow: View {
    let port: AttributedPort
    let openRoute: (NotificationRoute) -> Void

    private var owner: PortOwnerLabel { portOwnerLabel(port) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    if let url = URL(string: "http://localhost:\(port.port)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text(verbatim: ":\(port.port)").monospacedDigit()
                }
                .buttonStyle(.link)
                .help("Open http://localhost:\(port.port)")

                Text(port.command)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            ownerLine
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var ownerLine: some View {
        let label = owner
        HStack(spacing: 4) {
            if let route = label.route {
                Button { openRoute(route) } label: {
                    Text(label.title).lineLimit(1).truncationMode(.tail)
                }
                .buttonStyle(.link)
                .help(helpText(label))
            } else {
                Text(label.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let detail = label.detail {
                Text(detail)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .opacity(label.ended ? 0.7 : 1)
    }

    private func helpText(_ label: PortOwnerLabel) -> String {
        let owner = [label.detail, label.title].compactMap { $0 }.joined(separator: " — ")
        return label.ended ? "\(owner) (session ended)" : owner
    }
}

/// The listening ports Agent Board's processes hold, above Add Project in the sidebar (SPEC §10).
///
/// **Empty state: the header line and nothing else.** The sidebar already holds every project, so a
/// permanently drawn empty box would cost vertical space for no information. The header still costs
/// one line rather than zero because it carries the refresh button: a port that appeared since the
/// last hourly sweep is invisible until someone asks, and a panel that vanished entirely leaves
/// nobody to ask. An orphaned dev server is the row this epic exists for and it has no other
/// affordance.
struct PortsPanel: View {
    @Environment(AppEnvironment.self) private var env
    @AppStorage(PortsPanel.expandedKey) private var expanded = true

    static let expandedKey = "agentboard.portsPanel.expanded"

    var body: some View {
        if let model = env.listeningPorts {
            VStack(alignment: .leading, spacing: 2) {
                header(model)
                if expanded {
                    ForEach(model.ports) { port in
                        PortRow(port: port) { env.router.open($0) }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, model.ports.isEmpty || !expanded ? 0 : 4)
            .task { model.refresh() }
        }
    }

    private func header(_ model: ListeningPortModel) -> some View {
        HStack(spacing: 4) {
            Button {
                expanded.toggle()
                if expanded { model.refresh() }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Text("Ports").font(.caption).fontWeight(.medium)
                    if !model.ports.isEmpty {
                        Text(verbatim: "\(model.ports.count)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(model.ports.isEmpty ? "Nothing is listening" : "Listening ports Agent Board opened")

            Spacer(minLength: 4)

            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help("Refresh listening ports")
            .accessibilityLabel("Refresh listening ports")
        }
        .accessibilityElement(children: .contain)
    }
}
