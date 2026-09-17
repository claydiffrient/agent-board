import AppKit
import Observation

/// Asking the app to go away. It is not one call because AppKit refuses `NSApplication.terminate`
/// outright while any window has an attached sheet: no delegate is consulted, no
/// `NSApplication.willTerminateNotification` is posted, nothing is logged, and the call returns as
/// if it had worked. The control that asks for the quit lives inside such a sheet, so the sheet has
/// to be dismissed and its detachment observed before the app can be asked to go. Measured against
/// the shipped binary by `QuitProbe`; SPEC §2.
@MainActor
protocol AppQuitting: AnyObject {
    /// Why the last attempt came back instead of ending the process. Nil while none has.
    var refusal: String? { get }
    /// Dismiss your sheet first. Returns at once; an attempt that fails lands in `refusal`.
    func requestQuit()
    func dismissRefusal()
}

@Observable
@MainActor
final class AppQuit: AppQuitting {
    private(set) var refusal: String?

    /// Only one attempt runs at a time, and it is cleared when that attempt comes back. A latch
    /// that stayed shut would leave the quit control dead for the rest of the session.
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private let sheetedWindows: @MainActor () -> [String]
    @ObservationIgnored private let terminate: @MainActor () -> Void
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void

    /// How long to let a dismissed sheet detach before giving up on it, and how long to allow
    /// `terminate` to end the process before reporting that it did not.
    static let sheetPollInterval = Duration.milliseconds(50)
    static let sheetPolls = 40
    static let terminateGrace = Duration.seconds(2)

    init(
        sheetedWindows: @escaping @MainActor () -> [String] = AppQuit.windowsShowingSheets,
        terminate: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) },
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await _Concurrency.Task.sleep(for: $0) }
    ) {
        self.sheetedWindows = sheetedWindows
        self.terminate = terminate
        self.sleep = sleep
    }

    static func windowsShowingSheets() -> [String] {
        NSApp.windows.filter { $0.attachedSheet != nil }.map(\.title)
    }

    func requestQuit() {
        guard !inFlight else { return }
        inFlight = true
        refusal = nil
        _Concurrency.Task { @MainActor in
            let outcome = await attempt()
            inFlight = false
            refusal = outcome
        }
    }

    func dismissRefusal() { refusal = nil }

    /// Never nil: every path either finds a sheet still attached or outlives `terminate`, and
    /// `terminate` succeeding ends the process rather than returning here.
    private func attempt() async -> String {
        for _ in 0..<Self.sheetPolls {
            if sheetedWindows().isEmpty { break }
            await sleep(Self.sheetPollInterval)
        }
        let blocking = sheetedWindows()
        if !blocking.isEmpty { return Self.blocked(by: blocking) }
        terminate()
        await sleep(Self.terminateGrace)
        return "macOS did not quit Agent Board when it was asked to. Nothing was undone by the "
            + "attempt — the shutdown orders still stand — so quitting again, or from the Agent "
            + "Board menu, is safe."
    }

    private static func blocked(by titles: [String]) -> String {
        let named = titles.filter { !$0.isEmpty }
        let subject = named.isEmpty
            ? "A window is still showing a sheet"
            : named.map { "“\($0)”" }.joined(separator: ", ") + (named.count == 1 ? " is still showing a sheet" : " are still showing sheets")
        return "\(subject), and macOS will not quit an app while one is open. Close it and quit "
            + "again. The shutdown orders still stand in the meantime."
    }
}
