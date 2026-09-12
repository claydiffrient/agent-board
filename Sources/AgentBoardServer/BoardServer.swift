import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOCore

public enum BoardServerError: Error, Sendable {
    case failedToBind
    case alreadyRunning
}

public final class BoardServer: Sendable {
    private let tokens: any TokenResolver
    private let hooks: any HookSink
    private let tools: any ToolHandler
    private let logger: Logger
    private let runState = RunState()

    private static let sessionIdHeader = HTTPField.Name("Mcp-Session-Id")!
    private static let supportedProtocolVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18"]
    private static let latestProtocolVersion = "2025-06-18"

    public init(tokens: any TokenResolver, hooks: any HookSink, tools: any ToolHandler, logger: Logger? = nil) {
        self.tokens = tokens
        self.hooks = hooks
        self.tools = tools
        if let logger {
            self.logger = logger
        } else {
            var quiet = Logger(label: "agent-board-server")
            quiet.logLevel = .warning
            self.logger = quiet
        }
    }

    public var port: Int? {
        get async { await runState.port }
    }

    /// Running sessions hold config files pointing at the last port, so a stable port survives an app relaunch.
    /// Falls back to an ephemeral port when the preferred one is taken.
    public func start(preferredPort: Int? = nil) async throws -> Int {
        if let preferredPort, preferredPort > 0 {
            do { return try await bind(port: preferredPort) } catch BoardServerError.failedToBind {}
        }
        return try await bind(port: 0)
    }

    private func bind(port requestedPort: Int) async throws -> Int {
        guard await runState.task == nil else { throw BoardServerError.alreadyRunning }
        let (ports, portSink) = AsyncStream.makeStream(of: Int.self)
        let app = Application(
            router: buildRouter(),
            configuration: .init(address: .hostname("127.0.0.1", port: requestedPort), serverName: "agent-board"),
            onServerRunning: { channel in
                portSink.yield(channel.localAddress?.port ?? 0)
                portSink.finish()
            },
            logger: logger
        )
        let task = Task {
            defer { portSink.finish() }
            try await app.run()
        }
        await runState.set(task: task)
        for await port in ports where port != 0 {
            await runState.set(port: port)
            return port
        }
        await runState.clear()
        try await task.value
        throw BoardServerError.failedToBind
    }

    public func stop() async {
        guard let task = await runState.task else { return }
        await runState.clear()
        task.cancel()
        _ = try? await task.value
    }

    private func buildRouter() -> Router<BasicRequestContext> {
        let router = Router()
        router.post("/hooks", use: handleHook)
        router.post("/mcp", use: handleMCP)
        router.get("/mcp") { _, _ in Response(status: .methodNotAllowed) }
        router.delete("/mcp") { _, _ in Response(status: .ok) }
        return router
    }

    @Sendable
    private func handleHook(request: Request, context: BasicRequestContext) async throws -> Response {
        guard let token = request.uri.queryParameters["token"].map(String.init),
              let identity = await tokens.resolve(token: token)
        else {
            return unauthorized()
        }
        let body = try await request.body.collect(upTo: 8 << 20)
        guard let event = HookEvent(body: Data(body.readableBytesView)) else {
            return jsonResponse(status: .badRequest, body: ["error": "invalid json"])
        }
        await hooks.handle(event, identity: identity)
        return jsonResponse(status: .ok, body: [String: Any]())
    }

    @Sendable
    private func handleMCP(request: Request, context: BasicRequestContext) async throws -> Response {
        guard let authorization = request.headers[.authorization],
              authorization.hasPrefix("Bearer "),
              let identity = await tokens.resolve(token: String(authorization.dropFirst("Bearer ".count)))
        else {
            return unauthorized()
        }
        let body = try await request.body.collect(upTo: 4 << 20)
        let parsed = try? JSONSerialization.jsonObject(with: Data(body.readableBytesView))
        let messages: [[String: Any]]
        let isBatch: Bool
        switch parsed {
        case let single as [String: Any]:
            messages = [single]
            isBatch = false
        case let batch as [[String: Any]] where !batch.isEmpty:
            messages = batch
            isBatch = true
        default:
            return jsonResponse(status: .badRequest, body: rpcError(id: NSNull(), code: -32700, message: "Parse error"))
        }

        var responses: [[String: Any]] = []
        for message in messages {
            if let response = await dispatch(message, identity: identity) {
                responses.append(response)
            }
        }
        guard !responses.isEmpty else { return Response(status: .accepted) }

        var response = jsonResponse(status: .ok, body: isBatch ? responses : responses[0])
        if messages.contains(where: { $0["method"] as? String == "initialize" }) {
            response.headers[Self.sessionIdHeader] = UUID().uuidString
        }
        return response
    }

    private func dispatch(_ message: [String: Any], identity: TokenIdentity) async -> [String: Any]? {
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return id.map { rpcError(id: $0, code: -32600, message: "Invalid Request") }
        }
        guard let id else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return rpcResult(id: id, [
                "protocolVersion": Self.supportedProtocolVersions.contains(requested) ? requested : Self.latestProtocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "agent-board", "version": "0.1.0"],
            ])
        case "ping":
            return rpcResult(id: id, [String: Any]())
        case "tools/list":
            let descriptors = await tools.tools(for: identity)
            return rpcResult(id: id, ["tools": descriptors.map(render)])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return rpcError(id: id, code: -32602, message: "Missing tool name")
            }
            let arguments = JSONValue(any: params["arguments"] ?? [String: Any]())
            do {
                let result = try await tools.call(name, arguments: arguments, identity: identity)
                return rpcResult(id: id, toolResult(text: result.text, isError: result.isError))
            } catch let error as ToolError {
                return rpcResult(id: id, toolResult(text: error.message, isError: true))
            } catch {
                return rpcError(id: id, code: -32603, message: String(describing: error))
            }
        default:
            return rpcError(id: id, code: -32601, message: "Method not found")
        }
    }

    private func render(_ descriptor: ToolDescriptor) -> [String: Any] {
        [
            "name": descriptor.name,
            "description": descriptor.description,
            "inputSchema": descriptor.inputSchema.anyValue,
        ]
    }

    private func toolResult(text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private func rpcResult(id: Any, _ result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func rpcError(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func unauthorized() -> Response {
        jsonResponse(status: .unauthorized, body: ["error": "unauthorized"])
    }

    private func jsonResponse(status: HTTPResponse.Status, body: Any) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}

private actor RunState {
    private(set) var task: Task<Void, Error>?
    private(set) var port: Int?

    func set(task: Task<Void, Error>) {
        self.task = task
    }

    func set(port: Int) {
        self.port = port
    }

    func clear() {
        task = nil
        port = nil
    }
}
