import Darwin
import Foundation
import os

/// Logging that can name whoever double-closes a descriptor, which surfaces elsewhere as a
/// `Process.run()` failing with `NSPOSIXErrorDomain` 9.
enum DescriptorLog {
    static let logger = Logger(subsystem: "AgentBoard", category: "fd")
    static let keptArgumentLength = 120

    static func log(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    /// Reports `site` when the descriptor was already closed: a second close usually lands before the number is reused.
    static func closeChecked(_ fd: Int32, site: StaticString, report: (String) -> Void = log) {
        guard close(fd) == -1 else { return }
        let code = errno
        guard code == EBADF else { return }
        report("close(\(fd)) at \(site) failed with errno \(code) (\(String(cString: strerror(code))))")
    }

    static func launchFailed(
        _ executable: String, arguments: [String], cwd: URL?, descriptors: [(String, Int32)], error: Error
    ) {
        let shown = arguments.map { argument in
            argument.count > keptArgumentLength
                ? "\(argument.prefix(keptArgumentLength))…(\(argument.count) chars)" : argument
        }
        let fds = descriptors.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        log(
            "launch failed: \(executable) \(shown.joined(separator: " ")) cwd=\(cwd?.path ?? "inherited") "
                + "fds \(fds): \(error)"
        )
    }

    static func descriptors(_ name: String, _ pipe: Pipe) -> [(String, Int32)] {
        [
            ("\(name).read", pipe.fileHandleForReading.fileDescriptor),
            ("\(name).write", pipe.fileHandleForWriting.fileDescriptor),
        ]
    }
}
