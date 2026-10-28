import XCTest
@testable import AgentBoardRuntime

final class ProcessRunnerTests: XCTestCase {
    private static let shell = URL(fileURLWithPath: "/bin/sh")

    /// One call per core is enough to starve a stderr reader that waits on a dispatch queue: every
    /// call then sat out `pipeDrainTimeout` and threw, as a metering tick on a 3-core CI runner did.
    func testAsManyConcurrentRunsAsCoresAllReturnBothStreams() async throws {
        try await assertBurstReturnsBothStreams {
            try ProcessRunner.run(executable: Self.shell, arguments: ["-c", "echo out; echo err >&2"])
        }
    }

    /// The timed variant starved the same way, but past its grace it returned empty output instead
    /// of throwing, so `claude agents --json --all` read as no agents.
    func testAsManyConcurrentTimedRunsAsCoresAllReturnBothStreams() async throws {
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

    /// Each leaked pair stayed open for the app's lifetime; at the descriptor limit `Pipe()` handed out
    /// fd 0, and `claude agents --json` read back as empty stdout with exit 0.
    func testTimedRunsLeaveNoDescriptorsOpen() throws {
        let runs = 20
        let before = Self.openDescriptorCount()
        for _ in 0..<runs {
            try autoreleasepool {
                _ = try ProcessRunner.run(executable: Self.shell, arguments: ["-c", "echo out"], timeout: 10)
            }
        }
        XCTAssertLessThan(Self.openDescriptorCount() - before, runs)
    }

    private static func openDescriptorCount() -> Int {
        (0..<min(getdtablesize(), 8192)).filter { fcntl($0, F_GETFD) != -1 }.count
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

    /// A descriptor closed twice closes whatever another thread opened under the same number next,
    /// and that caller fails far away: a concurrent `Process.run()` throws NSPOSIXErrorDomain 9, as
    /// worktree setup did. The bystander pipes catch a stray close far more often than spawns do.
    func testConcurrentRunsNeverCloseADescriptorAnotherThreadOpened() {
        signal(SIGPIPE, SIG_IGN)
        let failures = Failures()
        let bystanders = DispatchGroup()
        for _ in 0..<4 {
            bystanders.enter()
            Thread.detachNewThread {
                defer { bystanders.leave() }
                while !failures.stopped {
                    var ends: [Int32] = [-1, -1]
                    guard pipe(&ends) == 0 else { continue }
                    var byte: UInt8 = 1
                    if write(ends[1], &byte, 1) != 1 { failures.add("bystander write: errno \(errno)") }
                    else if read(ends[0], &byte, 1) != 1 { failures.add("bystander read: errno \(errno)") }
                    if close(ends[0]) != 0 || close(ends[1]) != 0 { failures.add("bystander close: errno \(errno)") }
                }
            }
        }

        let environment = ["PATH": "/usr/bin:/bin"]
        let input = Data(repeating: 65, count: 300_000)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        DispatchQueue.concurrentPerform(iterations: 12) { worker in
            for round in 0..<40 {
                do {
                    switch (worker + round) % 9 {
                    case 0:
                        _ = try ProcessRunner.run(
                            executable: Self.shell, arguments: ["-c", "echo out; echo err >&2"], environment: environment
                        )
                    case 1:
                        let echoed = try ProcessRunner.run(
                            executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], stdin: input, environment: environment
                        )
                        if echoed.stdout.utf8.count != input.count { failures.add("cat returned \(echoed.stdout.utf8.count) bytes") }
                    case 2:
                        _ = try ProcessRunner.run(
                            executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], stdin: Data(), environment: environment
                        )
                    case 3:
                        _ = try ProcessRunner.run(executable: Self.shell, arguments: ["-c", "exit 3"], environment: environment, timeout: 30)
                    case 4:
                        do {
                            _ = try ProcessRunner.run(executable: Self.shell, arguments: ["-c", "sleep 5"], environment: environment, timeout: 0.1)
                            failures.add("a timed run outlived its timeout")
                        } catch let error as AgentRuntimeError where error.description.contains("did not finish") {}
                    case 5:
                        _ = try ProcessRunner.run(
                            executable: Self.shell, arguments: ["-c", "(sleep 1 &); echo out"], environment: environment, timeout: 30
                        )
                    case 6:
                        _ = try BoundedCommand.run(
                            executable: "/bin/sh", arguments: ["-c", "echo out"], cwd: tmp, environment: environment, timeout: 30
                        )
                    case 7:
                        _ = try BoundedCommand.run(
                            executable: "/bin/sh", arguments: ["-c", "sleep 5"], cwd: tmp, environment: environment, timeout: 0.1
                        )
                    default:
                        if LoginShellPath.query(shell: "/bin/sh", base: environment) == nil { failures.add("login shell query returned nil") }
                    }
                } catch {
                    failures.add(String(describing: error))
                }
            }
        }
        failures.stop()
        bystanders.wait()
        XCTAssertEqual(failures.all, [])
    }

    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        private var done = false

        var stopped: Bool { lock.withLock { done } }
        var all: [String] { lock.withLock { list } }
        func add(_ failure: String) { lock.withLock { list.append(failure) } }
        func stop() { lock.withLock { done = true } }
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
