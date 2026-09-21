import Foundation

/// Whether the app should be holding a power assertion, and what to tell the human about it.
///
/// SPEC §8.3. Measured on this Mac from `pmset -g log` on 2026-09-16: a lid close is logged as
/// `Clamshell Sleep`, a cause of its own, and it fires with `PreventUserIdleSystemSleep` held —
/// at 2026-09-13 15:59:18, on AC with the display on and two live assertions of that type, the
/// machine went to dark wake and then slept five seconds later. So this covers idle sleep and not
/// lid-close sleep, and every string here says so rather than implying full coverage.
public enum SleepPrevention {
    /// What `pmset -g assertions` prints under "Listed by owning process" — the only place a human
    /// can find out who is holding their Mac awake, so it names the app rather than the API.
    public static let assertionName = "Agent Board — an agent is running"

    /// Reads observed session state, never a spawn call: a worker that died without reporting stops
    /// holding the Mac awake as soon as the sweep flips its row to an inactive state.
    public static func shouldHold(enabled: Bool, states: [SessionState]) -> Bool {
        enabled && states.contains(where: \.isActive)
    }

    public static func activeCount(_ states: [SessionState]) -> Int {
        states.filter(\.isActive).count
    }

    public static func footerLabel(enabled: Bool, activeCount: Int) -> String {
        guard enabled else { return "Sleep prevention off" }
        guard activeCount > 0 else { return "Mac may sleep — nothing running" }
        return "Keeping this Mac awake — idle sleep only"
    }

    public static let lidCaveat = """
        Closing the lid still sleeps the Mac and kills every running worker. \
        Only external power plus an external display keeps a closed laptop running.
        """

    public static func footerHelp(enabled: Bool, activeCount: Int) -> String {
        guard enabled else {
            return "Agent Board is not holding a power assertion. The Mac sleeps on its own schedule "
                + "and a session running when it does is lost."
        }
        let head = activeCount > 0
            ? "Agent Board holds a system power assertion named “\(assertionName)” while \(activeCount) "
                + "\(activeCount == 1 ? "session is" : "sessions are") live. Check it with `pmset -g assertions`."
            : "Agent Board takes a power assertion as soon as a session starts. Nothing is running, so it holds none now."
        return head + " It prevents idle system sleep only — the display still sleeps as usual. " + lidCaveat
    }
}

/// The create/release half of sleep prevention, so a test can assert what was asked for without a
/// real IOKit assertion.
public protocol SleepAssertion: AnyObject {
    var isHeld: Bool { get }
    func hold(named name: String)
    func release()
}
