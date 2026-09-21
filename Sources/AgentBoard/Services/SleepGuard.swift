import AgentBoardCore
import AgentBoardRuntime
import AppKit
import Foundation
import Observation

/// One power assertion for the whole app, held while any session is live and released when the last
/// one ends, when the setting goes off, or when the app quits. SPEC §8.3.
@Observable
@MainActor
final class SleepGuard {
    static let defaultsKey = "sleep.preventWhileRunning"

    private(set) var isHolding = false
    private(set) var activeCount = 0

    /// Defaults on. Turning it off releases whatever is held on the same turn rather than waiting
    /// for the next metering tick.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.defaultsKey)
            apply(lastStates)
        }
    }

    @ObservationIgnored private let assertion: any SleepAssertion
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lastStates: [SessionState] = []

    init(assertion: any SleepAssertion = IOKitSleepAssertion(), defaults: UserDefaults = .standard) {
        self.assertion = assertion
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    func apply(_ states: [SessionState]) {
        lastStates = states
        activeCount = SleepPrevention.activeCount(states)
        if SleepPrevention.shouldHold(enabled: isEnabled, states: states) {
            assertion.hold(named: SleepPrevention.assertionName)
        } else {
            assertion.release()
        }
        isHolding = assertion.isHeld
    }

    /// Quitting with workers still running is the path that would otherwise strand the assertion:
    /// the process dies holding it and `pmset -g assertions` keeps naming an app that is gone.
    func releaseForTermination() {
        assertion.release()
        isHolding = false
    }

    @discardableResult
    func releaseOnTermination(center: NotificationCenter = .default) -> any NSObjectProtocol {
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.releaseForTermination() }
        }
    }

    var footerLabel: String { SleepPrevention.footerLabel(enabled: isEnabled, activeCount: activeCount) }
    var footerHelp: String { SleepPrevention.footerHelp(enabled: isEnabled, activeCount: activeCount) }
}
