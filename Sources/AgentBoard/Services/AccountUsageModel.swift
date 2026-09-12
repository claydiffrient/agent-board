import AgentBoardRuntime
import Foundation
import Observation

/// Polls Claude Code's cached account-usage block on its own timer.
///
/// Kept out of `WorkerSupervisor.meterTick` deliberately: this is view state with no bearing on
/// spawn control, and threading it through `WorkerSupervising` would put a UI concern in the
/// protocol that governs workers.
@MainActor
@Observable
final class AccountUsageModel {
    private(set) var snapshot: AccountUsageSnapshot?
    /// Bumped each poll so the "updated N ago" label re-renders without reading the file again.
    private(set) var observedAt = Date.now

    static let pollInterval: Duration = .seconds(60)

    @ObservationIgnored private let configURL: URL
    @ObservationIgnored private let refresher: AccountUsageRefresher

    nonisolated init(
        configURL: URL = AccountUsageReader.defaultConfigURL,
        refresher: AccountUsageRefresher = AccountUsageRefresher()
    ) {
        self.configURL = configURL
        self.refresher = refresher
    }

    func run() async {
        while !_Concurrency.Task.isCancelled {
            await tick()
            try? await _Concurrency.Task.sleep(for: Self.pollInterval)
        }
    }

    /// A read that fails keeps the last good reading on screen; `~/.claude.json` is rewritten often
    /// enough that a torn read would otherwise blank the bars.
    private func tick() async {
        if let reading = await read() { snapshot = reading }
        observedAt = .now
        guard snapshot?.isStale(at: observedAt) ?? true else { return }
        forceRefresh()
    }

    /// Fire and forget: the stale reading stays on screen while this runs, and survives a failure.
    private func forceRefresh() {
        _Concurrency.Task { [weak self, refresher] in
            guard await refresher.refreshIfAllowed() else { return }
            guard let self else { return }
            let reading = await self.read()
            guard let reading else { return }
            self.snapshot = reading
            self.observedAt = .now
        }
    }

    private func read() async -> AccountUsageSnapshot? {
        let url = configURL
        return await _Concurrency.Task.detached(priority: .utility) {
            AccountUsageReader.read(configAt: url)
        }.value
    }
}
