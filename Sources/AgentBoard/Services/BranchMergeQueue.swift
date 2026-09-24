/// Runs merges into the same target branch one after another, in arrival order (SPEC §5). A merge
/// borrows a worktree on its target, and git lets only one worktree hold a branch, so a second
/// merge that overlapped the first would fail instead of waiting.
@MainActor
final class BranchMergeQueue {
    /// A key is present while its branch is held; the array is who is waiting for it.
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    nonisolated init() {}

    func serialize<T>(repo: String, branch: String, _ body: () async -> T) async -> T {
        let key = repo + "\u{01}" + branch
        if waiters[key] == nil {
            waiters[key] = []
        } else {
            await withCheckedContinuation { waiters[key, default: []].append($0) }
        }
        defer { handOff(key) }
        return await body()
    }

    private func handOff(_ key: String) {
        guard var queue = waiters[key], !queue.isEmpty else {
            waiters[key] = nil
            return
        }
        let next = queue.removeFirst()
        waiters[key] = queue
        next.resume()
    }
}
