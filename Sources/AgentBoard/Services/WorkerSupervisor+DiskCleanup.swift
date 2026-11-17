import AgentBoardCore
import AgentBoardRuntime
import Foundation

enum DiskCleanupTrigger: Sendable {
    case lowDiskSpace
    case onDemand

    var name: String {
        switch self {
        case .lowDiskSpace: "Low disk space cleanup"
        case .onDemand: "Clean up now"
        }
    }
}

/// SPEC §14.4: sweep every project's finished worktrees, then run each cleanup command one at a
/// time, then post one follow-up notification.
extension WorkerSupervisor {
    func cleanUpOnLowDiskSpace() {
        let events = lowDiskSpaceEvents()
        _Concurrency.Task { [weak self] in
            for await _ in events {
                // Not awaited, so an event that arrives mid-run joins it rather than queuing a second run.
                _Concurrency.Task { await self?.cleanUpDisk(.lowDiskSpace) }
            }
        }
    }

    func cleanUpDiskNow() async {
        await cleanUpDisk(.onDemand)
    }

    /// Joins the cleanup already running, if any.
    @discardableResult
    func cleanUpDisk(_ trigger: DiskCleanupTrigger) async -> DiskCleanupSummary {
        if let diskCleanupRun { return await diskCleanupRun.value }
        let run = _Concurrency.Task { @MainActor in
            let summary = await self.runDiskCleanup(trigger)
            self.diskCleanupRun = nil
            return summary
        }
        diskCleanupRun = run
        return await run.value
    }

    private func runDiskCleanup(_ trigger: DiskCleanupTrigger) async -> DiskCleanupSummary {
        let all = (try? projects.list()) ?? []
        let paths = all.flatMap { [URL(fileURLWithPath: $0.repoPath), URL(fileURLWithPath: $0.worktreeRoot)] }
        let measure = measureVolumes
        let before = await _Concurrency.Task.detached { measure(paths) }.value

        var problems: [String] = []
        var sweeps: [String: WorktreeSweepResult] = [:]
        for project in all {
            do {
                sweeps[project.id] = try await sweepFinishedWorktreesUnrecorded(projectId: project.id)
            } catch {
                problems.append("Sweeping \(project.name) failed: \(error)")
            }
        }
        let afterSweep = await _Concurrency.Task.detached { measure(paths) }.value

        var commands: [String: ProjectCleanupResult] = [:]
        for project in all {
            guard let cleanup = project.settings.projectCleanup else { continue }
            let checkout = URL(fileURLWithPath: project.repoPath)
            let result = await _Concurrency.Task.detached { ProjectCleanupRunner.run(cleanup, in: checkout) }.value
            commands[project.id] = result
            if let result, let problem = DiskCleanupSummary.problem(result, projectName: project.name) {
                problems.append(problem)
            }
        }
        let after = await _Concurrency.Task.detached { measure(paths) }.value

        for project in all {
            let sweep = sweeps[project.id] ?? WorktreeSweepResult(projectId: project.id)
            do {
                try board.recordWorktreeSweep(sweep, trigger: trigger.name, cleanup: commands[project.id])
                announceReports(projectId: project.id)
            } catch {
                problems.append("Recording \(project.name)'s report failed: \(error)")
            }
        }

        let summary = DiskCleanupSummary(
            before: before, afterSweep: afterSweep, after: after,
            removed: sweeps.values.reduce(0) { $0 + $1.removed.count },
            kept: sweeps.values.reduce(0) { $0 + $1.kept.count },
            problems: problems
        )
        postBanner(summary.title, summary.body, nil)
        return summary
    }
}
