import Foundation
import IOKit.ps

public enum PowerSource {
    /// Whether the providing power source is AC. A Mac with no battery reports AC, and one whose
    /// source cannot be read counts as AC, so only a known battery or UPS holds anything back.
    public static func isOnAC() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return true }
        return (type as String) == kIOPMACPowerKey
    }
}
