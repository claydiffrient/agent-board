import XCTest
@testable import AgentBoardRuntime

final class ProcessRunnerTests: XCTestCase {
    private static let shell = URL(fileURLWithPath: "/bin/sh")

    /// One call per core is enough to starve a stderr reader that waits on a dispatch queue: every
    /// call then sat out `pipeDrainTimeout` and threw, as a metering tick on a 3-core CI runner did.
    func testAsManyConcurrentRunsAsCoresAllReturnBothStreams() async throws {
        // Resolved before any burst, as AppComposition does at launch; its lookup starves the same way.
        _ = LoginShellPath.resolved
        try await assertBurstReturnsBothStreams {
            try ProcessRunner.run(executable: Self.shell, arguments: ["-c", "echo out; echo err >&2"])
        }
    }

    /// The timed variant starved the same way, but past its grace it returned empty output instead
    /// of throwing, so `claude agents --json --all` read as no agents.
    func testAsManyConcurrentTimedRunsAsCoresAllReturnBothStreams() async throws {
        _ = LoginShellPath.resolved
        try await assertBurstReturnsBothStreams {
            try ProcessRunner.run(executable: Self.shell, arguments: ["-c", "echo out; echo err >&2"], timeout: 30)
        }
    }

    func testATimedRunReturnsAtTheChildsExitWhileAGrandchildHoldsItsPipes() throws {
        let result = try ProcessRunner.run(executable: Self.shell, arguments: ["-c", "sleep 60 & echo $!"], timeout: 10)
        let grandchild = try XCTUnwrap(pid_t(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        kill(grandchild, SIGKILL)
        XCTAssertEqual(result.status, 0)
    }

    /// A grandchild flooding a pipe holds the drain open only while it wins every refill race, which no
    /// real pipe does reliably. A datagram socket yields one byte per read, so a topped-up queue always does.
    func testADrainPastTheDeadlineReturnsWhatItHasOnceTheChildHasExited() throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_DGRAM, 0, &sockets), 0)
        let flooder = sockets[1]
        defer { close(flooder) }
        var queueBytes: Int32 = 1 << 20
        setsockopt(sockets[0], SOL_SOCKET, SO_RCVBUF, &queueBytes, socklen_t(MemoryLayout<Int32>.size))
        var noSigpipe: Int32 = 1
        setsockopt(flooder, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(flooder, F_SETFL, fcntl(flooder, F_GETFL) | O_NONBLOCK)
        while send(flooder, "y", 1, 0) == 1 {}
        let full = errno
        XCTAssert(full == ENOBUFS || full == EAGAIN, "filling the queue failed with errno \(full)")

        let flooding = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            while send(flooder, "y", 1, 0) == 1 || errno == ENOBUFS || errno == EAGAIN {}
            flooding.signal()
        }
        let drained = DispatchSemaphore(value: 0)
        let deadline = DispatchTime.now() + 0.5
        DispatchQueue.global().async {
            _ = drained.wait(timeout: deadline + 5)
            shutdown(flooder, SHUT_WR)
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        let stderr = Pipe()
        try stderr.fileHandleForWriting.close()

        let output = ProcessRunner.exchange(
            stdout: DatagramPipe(reading: FileHandle(fileDescriptor: sockets[0], closeOnDealloc: true)),
            stderr: stderr, stdin: nil, exitWatch: try ExitWatch(child), deadline: deadline
        )
        let returned = DispatchTime.now()
        drained.signal()
        flooding.wait()

        XCTAssertLessThan(returned, deadline + 1)
        XCTAssertFalse(try XCTUnwrap(output).stdout.isEmpty)
    }

    private final class DatagramPipe: Pipe, @unchecked Sendable {
        private let reading: FileHandle

        init(reading: FileHandle) {
            self.reading = reading
        }

        override var fileHandleForReading: FileHandle { reading }
    }

    private func assertBurstReturnsBothStreams(_ run: @escaping @Sendable () throws -> CommandResult) async throws {
        let results = try await withThrowingTaskGroup(of: CommandResult.self) { group in
            for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
                group.addTask { try run() }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        for result in results {
            XCTAssertEqual(result.stdout, "out\n")
            XCTAssertEqual(result.stderr, "err\n")
        }
    }
}
