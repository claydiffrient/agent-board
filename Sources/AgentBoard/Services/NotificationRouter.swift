import Observation

/// Carries a clicked banner's route from the notification delegate into the window. The views read
/// it; nothing else writes it.
@Observable
@MainActor
final class NotificationRouter {
    /// A view that acts on a route. Each takes a route once, however often it reappears.
    enum Consumer {
        case screen
        case epicLane
    }

    private(set) var route: NotificationRoute?
    /// Bumped on every open, so clicking the same banner twice routes twice. Views key their
    /// `task(id:)` on this rather than on the route.
    private(set) var sequence = 0
    @ObservationIgnored private var handled: [Consumer: Int] = [:]

    func open(_ route: NotificationRoute) {
        self.route = route
        sequence += 1
    }

    func take(_ consumer: Consumer, projectId: String) -> NotificationRoute? {
        guard let route, route.projectId == projectId, handled[consumer, default: 0] < sequence else { return nil }
        handled[consumer] = sequence
        return route
    }
}
