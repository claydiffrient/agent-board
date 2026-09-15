import Foundation

/// SwiftTerm's `LocalProcessTerminalViewDelegate.processTerminated(source:exitCode:)` hands back the
/// raw `waitpid` status, not the exit code, so `exit 7` arrives as 1792. Both `ShellConsole` and
/// `OrchestratorConsole` decode through here rather than each carrying their own copy.
public enum WaitStatus {
    /// A signalled child reports 128 + signal, the way every shell reports one.
    public static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}
