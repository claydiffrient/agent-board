import AgentBoardCore
import AppKit
import SwiftUI

/// Winding down every project at once, from At a Glance. Raises an order on each project, delivers
/// them all, shows the ordered sessions from every project in one list, and quits when they have
/// all closed.
///
/// It shares `ShutdownSheetBody` — and therefore the row states, the wording rules and the buttons
/// — with the per-project sheet; only the observation and the quit decision differ.
struct GlobalShutdownSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var snapshot = Observed<GlobalShutdownSnapshot>(.empty)
    /// The orders raised by this sheet, nil until the raising pass answers. The snapshot has to
    /// show all of them before the wind-down can be read as finished; otherwise the observation
    /// lagging one write behind looks identical to every worker having closed.
    @State private var raisedOrderIds: Set<String>?
    @State private var quitting = false
    @State private var errorMessage: String?

    private var rows: [ShutdownRow] {
        GlobalShutdown.rows(snapshot.value, awake: SleepLedger.shared.reading())
    }

    var body: some View {
        let rows = rows
        let counts = GlobalShutdown.counts(rows: rows)
        let ordersRaised = raisedOrderIds.map { GlobalShutdown.ordersVisible(in: snapshot.value, raised: $0) } ?? false
        let decision = GlobalShutdown.decide(counts: counts, ordersRaised: ordersRaised)
        return ShutdownSheetBody(
            headline: ordersRaised
                ? GlobalShutdown.headline(counts: counts, projects: snapshot.value.projectCount)
                : "Ordering every project to wind down…",
            detail: GlobalShutdown.detail(counts: counts, projects: snapshot.value.projectCount, decision: decision),
            isComplete: decision == .quit,
            rows: rows,
            footerNote: "Spawning is refused on every project while this stands.",
            attach: { openWindow(id: "terminal", value: $0) },
            stop: { sessionId in run { try await env.supervisor.stop(sessionId: sessionId) } }
        ) {
            Button("Cancel Shutdown") { cancel() }
                .help("Lifts the order on every project. Workers that already stopped stay stopped.")
            Button(decision == .quit ? "Quit Agent Board" : "Quit Anyway") { quit() }
                .keyboardShortcut(decision == .quit ? .defaultAction : .init(.escape, modifiers: []))
                .help(decision == .quit
                    ? "Every worker has closed."
                    : "Leaves the sessions that have not closed running, and the orders standing so they wind down on the next launch.")
        }
        .task {
            await snapshot.run(GlobalShutdownStore(env.db).observe(), in: env.db.reader)
        }
        .task {
            await raiseOrders()
        }
        .onChange(of: decision, initial: true) {
            if decision == .quit { quit() }
        }
        .errorAlert($errorMessage)
    }

    private func raiseOrders() async {
        do {
            raisedOrderIds = Set(try await env.supervisor.requestGlobalShutdown(requestedBy: "human", reason: nil).map(\.id))
        } catch {
            errorMessage = errorText(error)
        }
    }

    /// Every order is lifted, not only the ones with rows on screen: a project left refusing spawns
    /// after this sheet closes has nothing on screen to explain itself.
    private func cancel() {
        run {
            _ = try await env.supervisor.cancelGlobalShutdown(by: "human")
            await MainActor.run { dismiss() }
        }
    }

    /// The orders are deliberately left standing. A session that never acknowledged is a detached
    /// `claude --bg` process that outlives the app, and the order still on its project is what
    /// hands it the wind-down through `PreToolUse` once the board server is back.
    private func quit() {
        guard !quitting else { return }
        quitting = true
        env.supervisor.stopOrchestratorConsoles()
        NSApplication.shared.terminate(nil)
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        _Concurrency.Task {
            do {
                try await operation()
            } catch {
                errorMessage = errorText(error)
            }
        }
    }
}
