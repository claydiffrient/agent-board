import AgentBoardCore
import Foundation
import IOKit.pwr_mgt

/// Holds `kIOPMAssertPreventUserIdleSystemSleep` and nothing else. Display sleep has its own
/// assertion type, `kIOPMAssertPreventUserIdleDisplaySleep`, which is deliberately never taken: a
/// screen lit all night is not what keeps a worker alive. SPEC §8.3.
public final class IOKitSleepAssertion: SleepAssertion {
    private var assertionId: IOPMAssertionID?

    public init() {}

    public var isHeld: Bool { assertionId != nil }

    public func hold(named name: String) {
        guard assertionId == nil else { return }
        var created = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &created
        )
        guard result == kIOReturnSuccess else { return }
        assertionId = created
    }

    public func release() {
        guard let assertionId else { return }
        IOPMAssertionRelease(assertionId)
        self.assertionId = nil
    }

    deinit {
        if let assertionId { IOPMAssertionRelease(assertionId) }
    }
}
