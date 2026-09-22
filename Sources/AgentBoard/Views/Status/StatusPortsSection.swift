import AgentBoardCore
import SwiftUI

/// This project's listening ports, between the roster and the Status footer (SPEC §10).
///
/// Reads `ListeningPortModel.ports(inProject:)` — the sidebar panel's sweep, filtered. It starts no
/// sweep and owns no refresh affordance: the panel that does is on screen beside this one, and a
/// second timer over the same process table would double the cost and let the two disagree between
/// ticks.
///
/// **An orphan appears here whenever its ended session still names a project.** `agent_session` and
/// `task` outlive the process, so a ledger-sourced row resolves a `projectId` and lands in the pane
/// for that project — the dev server whose session ended an hour ago is exactly the row this is for.
///
/// Nothing is drawn when this project holds no ports. The sidebar panel keeps its header line even
/// when empty because that line carries the refresh button; this section carries no button, so an
/// empty one would cost the roster vertical space for no information.
struct StatusPortsSection: View {
    let project: Project

    @Environment(AppEnvironment.self) private var env

    private var ports: [AttributedPort] {
        env.listeningPorts.map { $0.ports(inProject: project.id) } ?? []
    }

    var body: some View {
        if let model = env.listeningPorts, !ports.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "network").font(.system(size: 9))
                    Text("Ports").fontWeight(.medium)
                    Text(verbatim: "\(ports.count)").monospacedDigit()
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(ports) { port in
                    PortRow(
                        port: port,
                        openRoute: { env.router.open($0) },
                        isStopping: model.isStopping(port),
                        stopFailure: model.stopFailure(for: port),
                        stop: { _Concurrency.Task { await model.stop(port) } }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}
