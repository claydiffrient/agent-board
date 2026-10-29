import Foundation

/// CDR's state directory: `$CD_REVIEW_HOME`, else `~/.cd-review` (CDR's `server/paths.mjs`). SPEC §13.7.
public struct CDRHome: Equatable, Sendable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CDRHome {
        if let configured = environment["CD_REVIEW_HOME"], !configured.isEmpty {
            return CDRHome(url: URL(fileURLWithPath: configured))
        }
        return CDRHome(url: home.appendingPathComponent(".cd-review"))
    }

    var watcherFile: URL { url.appendingPathComponent("watcher.json") }
    var serverFile: URL { url.appendingPathComponent("server.json") }
}

/// What the CDR watcher daemon is doing, read from its state file and its control port.
public enum CDRDaemonState: Equatable, Sendable {
    /// No CDR home directory.
    case notInstalled
    case stopped
    case running(CDRStatus)
    /// The state file and the port disagree, or the daemon answered but its status could not be read.
    case unreachable(String)
}

/// The review server's targets, or why they could not be read. Independent of the daemon's state.
public enum CDRReviewsState: Equatable, Sendable {
    case available(CDRReviewList)
    case serverNotRunning
    case failed(String)
}

public struct CDRReviewList: Equatable, Sendable {
    /// The review server's origin; its page routes need no token.
    public var baseURL: URL
    public var targets: [CDRTarget]

    public func pageURL(for target: CDRTarget) -> URL {
        baseURL.appendingPathComponent(target.pagePath)
    }

    /// Every review of every target, newest start first.
    public var recent: [CDRRecentReview] {
        targets
            .flatMap { target in target.reviews.map { (CDRRecentReview(target: target, review: $0), $0.startedDate ?? .distantPast) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

public struct CDRRecentReview: Equatable, Sendable {
    public var target: CDRTarget
    public var review: CDRReview
}

public struct CDRSnapshot: Equatable, Sendable {
    public var daemon: CDRDaemonState
    public var reviews: CDRReviewsState
}

/// `{port, pid, token}` from `watcher.json` or `server.json`. It holds a bearer token, so it stays internal and
/// its description leaves the token out.
struct CDRServiceFile: Decodable, CustomStringConvertible, CustomDebugStringConvertible {
    var port: Int
    var pid: Int?
    var token: String

    static func read(_ url: URL) -> CDRServiceFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CDRServiceFile.self, from: data)
    }

    var description: String { "CDRServiceFile(port: \(port), pid: \(pid.map(String.init) ?? "nil"))" }
    var debugDescription: String { description }
}

/// Reads CDR's two local services: the watcher daemon's `/health` and `/status`, and the review server's
/// `/api/targets`. Read-only; start and stop go through `CDRCommand`. SPEC §13.7.
public struct CDRClient: Sendable {
    public static let watcherPort = 7718

    public var home: CDRHome
    /// Probed when `watcher.json` is missing, to find a daemon running without its state file.
    public var watcherDefaultPort: Int
    public var timeout: TimeInterval

    public init(
        home: CDRHome = .resolve(),
        watcherDefaultPort: Int = Int(ProcessInfo.processInfo.environment["CDR_PORT"] ?? "") ?? CDRClient.watcherPort,
        timeout: TimeInterval = 3
    ) {
        self.home = home
        self.watcherDefaultPort = watcherDefaultPort
        self.timeout = timeout
    }

    public func snapshot() async -> CDRSnapshot {
        async let daemon = daemonState()
        async let reviews = reviews()
        return await CDRSnapshot(daemon: daemon, reviews: reviews)
    }

    public func daemonState() async -> CDRDaemonState {
        guard FileManager.default.fileExists(atPath: home.url.path) else { return .notInstalled }
        let info = CDRServiceFile.read(home.watcherFile)
        let port = info?.port ?? watcherDefaultPort
        var health: CDRHealth?
        if case .success((200, let body)) = await get(port: port, path: "/health", token: nil) {
            health = try? JSONDecoder().decode(CDRHealth.self, from: body)
        }

        guard let info else {
            guard let health, health.service == "cdr" else { return .stopped }
            return .unreachable(
                "A CDR daemon (pid \(health.pid.map(String.init) ?? "unknown")) answers on port \(port), "
                    + "but \(home.watcherFile.path) is missing."
            )
        }
        guard let health, health.service == "cdr", health.pid == info.pid else {
            return .unreachable(
                "\(home.watcherFile.path) names pid \(info.pid.map(String.init) ?? "unknown") on port \(port), "
                    + "which is not answering as that daemon."
            )
        }
        switch await get(port: port, path: "/status", token: info.token) {
        case .success((200, let body)):
            guard let status = try? JSONDecoder().decode(CDRStatus.self, from: body) else {
                return .unreachable("The daemon's /status was not a JSON object.")
            }
            return .running(status)
        case .success((let code, let body)):
            return .unreachable("The daemon's /status answered HTTP \(code): \(Self.errorText(body, token: info.token))")
        case .failure(let failure):
            return .unreachable("The daemon's /status could not be read: \(failure.text)")
        }
    }

    public func reviews() async -> CDRReviewsState {
        guard let info = CDRServiceFile.read(home.serverFile) else { return .serverNotRunning }
        switch await get(port: info.port, path: "/api/targets", token: info.token) {
        case .success((200, let body)):
            guard let payload = try? JSONDecoder().decode(CDRTargetsPayload.self, from: body) else {
                return .failed("The review server's /api/targets was not a JSON object.")
            }
            return .available(CDRReviewList(baseURL: Self.origin(port: info.port), targets: payload.targets))
        case .success((let code, let body)):
            return .failed("The review server answered HTTP \(code): \(Self.errorText(body, token: info.token))")
        case .failure(.notListening):
            return .serverNotRunning
        case .failure(let failure):
            return .failed("The review server could not be reached: \(failure.text)")
        }
    }

    static func origin(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    /// CDR's `{error}` body, with the token cut out in case a future error message ever echoes it.
    static func errorText(_ body: Data, token: String) -> String {
        let text = (try? JSONDecoder().decode(CDRErrorBody.self, from: body))?.error
            ?? String(decoding: body.prefix(500), as: UTF8.self)
        return text.replacingOccurrences(of: token, with: "<token>")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum FetchFailure: Error {
        case notListening
        case other(String)

        var text: String {
            switch self {
            case .notListening: "nothing is listening"
            case .other(let text): text
            }
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    /// `127.0.0.1:<port>` is the only Host both CDR services accept (`sameOrigin` in each).
    private func get(port: Int, path: String, token: String?) async -> Result<(Int, Data), FetchFailure> {
        var request = URLRequest(url: Self.origin(port: port).appendingPathComponent(path), timeoutInterval: timeout)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (body, response) = try await Self.session.data(for: request)
            return .success(((response as? HTTPURLResponse)?.statusCode ?? 0, body))
        } catch let error as URLError where error.code == .cannotConnectToHost {
            return .failure(.notListening)
        } catch {
            return .failure(.other(error.localizedDescription))
        }
    }
}

private struct CDRHealth: Decodable {
    var service: String?
    var pid: Int?
}

private struct CDRErrorBody: Decodable {
    var error: String
}

private struct CDRTargetsPayload: Decodable {
    var targets: [CDRTarget]

    init(from decoder: Decoder) throws {
        targets = try decoder.container(keyedBy: CDRKey.self).list("targets")
    }
}

/// Starts and stops the CDR daemon through CDR's own CLI, `node <cli.mjs> start|stop`, rather than managing the
/// process itself. SPEC §13.7.
public struct CDRCommand: Equatable, Sendable {
    public var node: URL
    public var cli: URL
    public var timeout: TimeInterval

    public init(node: URL, cli: URL, timeout: TimeInterval = 60) {
        self.node = node
        self.cli = cli
        self.timeout = timeout
    }

    /// The "CDR command" setting when it is set, else `<installPath>/watcher/cli.mjs` of the installed
    /// `cd@cd-ai-skills` plugin when that file exists.
    public static func cliPath(
        configured: String?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> URL? {
        let configured = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        }
        let registry = home.appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: registry),
              let installs = try? JSONDecoder().decode(InstalledPlugins.self, from: data).plugins["cd@cd-ai-skills"]
        else { return nil }
        return installs.lazy
            .compactMap(\.installPath)
            .map { URL(fileURLWithPath: $0).appendingPathComponent("watcher/cli.mjs") }
            .first { fileExists($0.path) }
    }

    /// The first `node` on the login-shell PATH, which a Finder or Dock launch does not inherit (SPEC §2).
    /// Blocks on that PATH's lookup, so call it off the main actor.
    public static func nodePath(
        searchPath: String? = ChildEnvironment.sanitized()["PATH"],
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> URL? {
        (searchPath ?? "").split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("node") }
            .first { isExecutable($0.path) }
    }

    public static func resolve(configured: String?) -> Result<CDRCommand, CDRCommandError> {
        guard let cli = cliPath(configured: configured), FileManager.default.fileExists(atPath: cli.path) else {
            return .failure(.cliNotFound(configured: configured))
        }
        guard let node = nodePath() else { return .failure(.nodeNotFound) }
        return .success(CDRCommand(node: node, cli: cli))
    }

    /// Never `--force`: a restart while reviews run fails with exit 5 and that stderr is shown instead.
    /// Blocking; call it off the main actor.
    public func start() throws -> CDRCommandReport {
        try run("start")
    }

    public func stop() throws -> CDRCommandReport {
        try run("stop")
    }

    private func run(_ subcommand: String) throws -> CDRCommandReport {
        let result: CommandResult
        do {
            result = try ProcessRunner.run(
                executable: node, arguments: [cli.path, subcommand], environment: ChildEnvironment.sanitized(),
                timeout: timeout
            )
        } catch {
            throw CDRCommandError.didNotFinish("\(error)")
        }
        guard result.status == 0 else {
            throw CDRCommandError.failed(
                status: result.status, stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return (try? JSONDecoder().decode(CDRCommandReport.self, from: Data(result.stdout.utf8))) ?? CDRCommandReport()
    }
}

private struct InstalledPlugins: Decodable {
    struct Install: Decodable {
        var installPath: String?
    }

    var plugins: [String: [Install]]
}

public enum CDRCommandError: Error, Equatable, CustomStringConvertible, Sendable {
    case cliNotFound(configured: String?)
    case nodeNotFound
    case failed(status: Int32, stderr: String)
    case didNotFinish(String)

    /// `cdr start` refused to restart a daemon whose code or config moved because reviews are running.
    public var reviewsRunning: Bool {
        if case .failed(5, _) = self { true } else { false }
    }

    public var description: String {
        switch self {
        case .cliNotFound(let configured):
            if let configured, !configured.trimmingCharacters(in: .whitespaces).isEmpty {
                "CDR's CLI is not at \(configured). Set Settings → CDR → CDR command to CDR's watcher/cli.mjs."
            } else {
                "CDR's CLI was not found. Set Settings → CDR → CDR command to CDR's watcher/cli.mjs."
            }
        case .nodeNotFound:
            "node is not on the login shell's PATH."
        case .failed(let status, let stderr):
            stderr.isEmpty ? "CDR exited \(status)." : stderr
        case .didNotFinish(let detail):
            detail
        }
    }
}

/// `start` prints `{state, pid, port, log}`; `stop` prints `{stopped, pid}` or `{stopped: false, state}`.
public struct CDRCommandReport: Decodable, Equatable, Sendable {
    public var state: String?
    public var stopped: Bool?
    public var pid: Int?
    public var port: Int?
    public var note: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CDRKey.self)
        state = c.lenient("state")
        stopped = c.lenient("stopped")
        pid = c.lenient("pid")
        port = c.lenient("port")
        note = c.lenient("note")
    }
}
