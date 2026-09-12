extension BoardTask {
    /// Tasks a worker has finished, in the order the review column shows them.
    public static func pendingReview(in tasks: [BoardTask]) -> [BoardTask] {
        tasks
            .filter { $0.column == .review }
            .sorted { ($0.ordering, $0.createdAt, $0.id) < ($1.ordering, $1.createdAt, $1.id) }
    }
}
