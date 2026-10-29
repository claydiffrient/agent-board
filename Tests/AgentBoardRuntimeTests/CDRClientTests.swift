import Network
import XCTest
@testable import AgentBoardRuntime

final class CDRClientTests: XCTestCase {
    private let token = "0d9f-test-bearer-token-7c21"
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("cdr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testARunningDaemonDecodesItsStatusWhileTheReviewServerIsDown() async throws {
        let daemon = try CDRStubServer(token: token, routes: [
            "/health": (200, Data(#"{"ok":true,"service":"cdr","pid":41001,"home":"/x"}"#.utf8)),
            "/status": (200, try fixture("cdr-status")),
        ])
        let refused = try RefusingPort()
        try writeServiceFile("watcher.json", port: daemon.port, pid: 41001)
        try writeServiceFile("server.json", port: refused.port, pid: 41002)

        let snapshot = await CDRClient(home: CDRHome(url: home), watcherDefaultPort: refused.port).snapshot()

        guard case .running(let status) = snapshot.daemon else { return XCTFail("daemon read as \(snapshot.daemon)") }
        let polling = try XCTUnwrap(status.polling)
        XCTAssertEqual(polling.running.map(\.pr), [412])
        XCTAssertEqual(polling.running.first?.phase, "reviewing")
        XCTAssertEqual(polling.queued.map(\.blockedBy), ["concurrency"], "the malformed queue entry is dropped, not the list")
        XCTAssertEqual(polling.waiting.map(\.repo), ["octo/gadgets"])
        XCTAssertEqual(polling.reviewed.map(\.reviewId), [311])
        XCTAssertNil(polling.paused, "CDR sends paused: false when nothing holds the loop")
        XCTAssertEqual(polling.budget?.used, 4)
        XCTAssertEqual(polling.concurrency?.limit, 2)
        XCTAssertEqual(snapshot.reviews, .serverNotRunning)
    }

    func testAStoppedDaemonStillListsRecentReviewsNewestFirst() async throws {
        let server = try CDRStubServer(token: token, routes: ["/api/targets": (200, try fixture("cdr-targets"))])
        let refused = try RefusingPort()
        try writeServiceFile("server.json", port: server.port, pid: 41002)

        let snapshot = await CDRClient(home: CDRHome(url: home), watcherDefaultPort: refused.port).snapshot()

        XCTAssertEqual(snapshot.daemon, .stopped)
        guard case .available(let list) = snapshot.reviews else { return XCTFail("reviews read as \(snapshot.reviews)") }
        XCTAssertEqual(list.targets.map(\.id), [12, 15], "a target with no id is dropped")
        XCTAssertEqual(list.recent.map(\.review.id), [311, 305, 300])
        XCTAssertEqual(list.recent.first?.review.source, "cdr")
        XCTAssertEqual(list.recent.first?.review.lensesFailed, 1)
        XCTAssertEqual(list.targets.first?.prState, "merged")
        XCTAssertEqual(list.pageURL(for: list.targets[0]).absoluteString, "http://127.0.0.1:\(server.port)/t/12")
    }

    func testAStateFileWhoseDaemonDoesNotAnswerIsUnreachableNotStopped() async throws {
        let refused = try RefusingPort()
        try writeServiceFile("watcher.json", port: refused.port, pid: 41001)

        let state = await CDRClient(home: CDRHome(url: home), watcherDefaultPort: refused.port).daemonState()

        guard case .unreachable(let reason) = state else { return XCTFail("daemon read as \(state)") }
        XCTAssertTrue(reason.contains("watcher.json"), reason)
    }

    func testNoCDRHomeReadsAsNotInstalled() async throws {
        let refused = try RefusingPort()
        let missing = CDRHome(url: home.appendingPathComponent("absent"))

        let snapshot = await CDRClient(home: missing, watcherDefaultPort: refused.port).snapshot()

        XCTAssertEqual(snapshot.daemon, .notInstalled)
        XCTAssertEqual(snapshot.reviews, .serverNotRunning)
    }

    func testAnHTTPErrorThatEchoesTheTokenNeverSurfacesIt() async throws {
        let body = Data(#"{"error":"token \#(token) was revoked"}"#.utf8)
        let server = try CDRStubServer(token: token, routes: ["/api/targets": (401, body)])
        try writeServiceFile("server.json", port: server.port, pid: 41002)

        let reviews = await CDRClient(home: CDRHome(url: home)).reviews()

        guard case .failed(let reason) = reviews else { return XCTFail("reviews read as \(reviews)") }
        XCTAssertTrue(reason.contains("HTTP 401"), reason)
        XCTAssertFalse(reason.contains(token), reason)
    }

    func testStartAndStopRunCDRsCLIAndAFailureReturnsItsStderr() throws {
        let cli = home.appendingPathComponent("cli.sh")
        let calls = home.appendingPathComponent("calls")
        try """
        echo "$@" >> '\(calls.path)'
        case "$1" in
          start) echo 'CDR needs a restart (config changed), but 1 review(s) are running:' >&2; exit 5 ;;
          stop) echo '{"stopped": true, "pid": 41001}' ;;
        esac
        """.write(to: cli, atomically: true, encoding: .utf8)
        let command = CDRCommand(node: URL(fileURLWithPath: "/bin/sh"), cli: cli)

        XCTAssertThrowsError(try command.start()) { error in
            let failure = error as? CDRCommandError
            XCTAssertEqual(failure?.reviewsRunning, true)
            XCTAssertEqual(failure?.description, "CDR needs a restart (config changed), but 1 review(s) are running:")
        }
        XCTAssertEqual(try command.stop().stopped, true)
        XCTAssertEqual(try String(contentsOf: calls), "start\nstop\n", "start never passes --force")
    }

    func testTheCDRCommandSettingWinsAndTheInstalledPluginIsTheFallback() throws {
        let install = home.appendingPathComponent("plugin")
        let registry = home.appendingPathComponent(".claude/plugins/installed_plugins.json")
        try FileManager.default.createDirectory(at: registry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"version":2,"plugins":{"cd@cd-ai-skills":[{"scope":"user","installPath":"\#(install.path)"}]}}"#
            .write(to: registry, atomically: true, encoding: .utf8)

        XCTAssertNil(CDRCommand.cliPath(configured: "", home: home), "no cli.mjs at the install path")
        try FileManager.default.createDirectory(at: install.appendingPathComponent("watcher"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: install.appendingPathComponent("watcher/cli.mjs").path, contents: nil)
        XCTAssertEqual(CDRCommand.cliPath(configured: "  ", home: home)?.path, install.appendingPathComponent("watcher/cli.mjs").path)
        XCTAssertEqual(CDRCommand.cliPath(configured: "/opt/cdr/watcher/cli.mjs", home: home)?.path, "/opt/cdr/watcher/cli.mjs")

        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("node").path, contents: nil, attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(CDRCommand.nodePath(searchPath: "\(home.path)/none:\(bin.path)")?.path, bin.appendingPathComponent("node").path)
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }

    private func writeServiceFile(_ name: String, port: Int, pid: Int) throws {
        try #"{"port":\#(port),"pid":\#(pid),"token":"\#(token)","version":"0.1.0"}"#
            .write(to: home.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

/// Answers the way both CDR services do: 403 to any Host but `127.0.0.1:<port>`, and 401 without the bearer
/// token on everything except `/health`.
private final class CDRStubServer {
    private(set) var port = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cdr-stub")
    private let token: String
    private let routes: [String: (Int, Data)]

    init(token: String, routes: [String: (Int, Data)]) throws {
        self.token = token
        self.routes = routes
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            throw AgentRuntimeError("the CDR stub never started listening")
        }
        self.port = Int(port)
    }

    deinit { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return connection.cancel() }
            let buffer = buffer + (data ?? Data())
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                respond(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if done || error != nil {
                connection.cancel()
            } else {
                receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let (status, body): (Int, Data) = if headers["host"] != "127.0.0.1:\(port)" {
            (403, Data(#"{"error":"wrong host"}"#.utf8))
        } else if path != "/health", headers["authorization"] != "Bearer \(token)" {
            (401, Data(#"{"error":"bearer token required"}"#.utf8))
        } else {
            routes[path] ?? (404, Data(#"{"error":"no route"}"#.utf8))
        }
        let head = "HTTP/1.1 \(status) Stub\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// A loopback port nothing listens on. Bound but not listening is not enough: macOS drops the SYN, so the connect
/// times out instead of being refused.
private struct RefusingPort {
    let port: Int

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, length) == 0 && getsockname(descriptor, generic, &length) == 0
            }
        }
        guard descriptor >= 0, bound else { throw AgentRuntimeError("could not bind a loopback port") }
        port = Int(UInt16(bigEndian: address.sin_port))
    }
}
