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
    private let resources: (any ResourceHandler)?
    private let prompts: (any PromptHandler)?
    private let logger: Logger
    private let runState = RunState()

    private static let sessionIdHeader = HTTPField.Name("Mcp-Session-Id")!
    private static let supportedProtocolVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18"]
    private static let latestProtocolVersion = "2025-06-18"

    public init(
        tokens: any TokenResolver,
        hooks: any HookSink,
        tools: any ToolHandler,
        resources: (any ResourceHandler)? = nil,
        prompts: (any PromptHandler)? = nil,
        logger: Logger? = nil
    ) {
        self.tokens = tokens
        self.hooks = hooks
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
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
            do { return try await bind(port: preferredPort) } catch {
                logger.warning("port \(preferredPort) unavailable (\(error)); falling back to an ephemeral port")
            }
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
        guard let decision = await hooks.handle(event, identity: identity) else {
            return jsonResponse(status: .ok, body: [String: Any]())
        }
        return jsonResponse(status: .ok, body: decision.responseBody(hookEventName: event.name))
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
        var afterResponse: [@Sendable () async -> Void] = []
        for message in messages {
            if let response = await dispatch(message, identity: identity, afterResponse: &afterResponse) {
                responses.append(response)
            }
        }
        guard !responses.isEmpty else { return running(afterResponse, after: Response(status: .accepted)) }

        var response = jsonResponse(status: .ok, body: isBatch ? responses : responses[0])
        if messages.contains(where: { $0["method"] as? String == "initialize" }) {
            response.headers[Self.sessionIdHeader] = UUID().uuidString
        }
        return running(afterResponse, after: response)
    }

    /// A tool that ends the calling session cannot run before its own answer is written, or the
    /// client it kills never sees the reply and resends. Deferred work is therefore hung off the
    /// response body, not off the handler, and runs whether the write succeeded or threw — a
    /// session left unstopped here would sit idle forever.
    private func running(_ work: [@Sendable () async -> Void], after response: Response) -> Response {
        guard !work.isEmpty else { return response }
        var response = response
        let body = response.body
        response.body = ResponseBody(contentLength: body.contentLength) { writer in
            do {
                try await body.write(writer)
            } catch {
                for item in work { await item() }
                throw error
            }
            for item in work { await item() }
        }
        return response
    }

    private func dispatch(
        _ message: [String: Any], identity: TokenIdentity, afterResponse: inout [@Sendable () async -> Void]
    ) async -> [String: Any]? {
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return id.map { rpcError(id: $0, code: -32600, message: "Invalid Request") }
        }
        guard let id else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            var capabilities: [String: Any] = ["tools": [String: Any]()]
            // Neither `subscribe` nor `listChanged`: responses here are plain JSON over POST and
            // GET /mcp is 405, so there is no channel on which a server notification could arrive.
            if resources != nil { capabilities["resources"] = [String: Any]() }
            if prompts != nil {
                capabilities["prompts"] = ["listChanged": false]
            }
            return rpcResult(id: id, [
                "protocolVersion": Self.supportedProtocolVersions.contains(requested) ? requested : Self.latestProtocolVersion,
                "capabilities": capabilities,
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
                if let deferred = result.afterResponse { afterResponse.append(deferred) }
                return rpcResult(id: id, toolResult(text: result.text, isError: result.isError))
            } catch let error as ToolError {
                return rpcResult(id: id, toolResult(text: error.message, isError: true))
            } catch {
                return rpcError(id: id, code: -32603, message: String(describing: error))
            }
        case "resources/list":
            guard let resources else { return rpcError(id: id, code: -32601, message: "Method not found") }
            do {
                let descriptors = try await resources.resources(for: identity)
                return rpcResult(id: id, ["resources": descriptors.map(render)])
            } catch {
                return rpcError(id: id, code: -32603, message: String(describing: error))
            }
        case "resources/templates/list":
            guard resources != nil else { return rpcError(id: id, code: -32601, message: "Method not found") }
            return rpcResult(id: id, ["resourceTemplates": [Any]()])
        case "resources/read":
            guard let resources else { return rpcError(id: id, code: -32601, message: "Method not found") }
            guard let uri = params["uri"] as? String else {
                return rpcError(id: id, code: -32602, message: "Missing resource uri")
            }
            do {
                let contents = try await resources.read(uri, identity: identity)
                return rpcResult(id: id, ["contents": contents.map(render)])
            } catch let error as ResourceError {
                return resourceNotFound(id: id, uri: error.uri, message: error.message)
            } catch {
                return rpcError(id: id, code: -32603, message: String(describing: error))
            }
        case "prompts/list":
            guard let prompts else { return rpcError(id: id, code: -32601, message: "Method not found") }
            let descriptors = await prompts.prompts(for: identity)
            return rpcResult(id: id, ["prompts": descriptors.map(render)])
        case "prompts/get":
            guard let prompts else { return rpcError(id: id, code: -32601, message: "Method not found") }
            guard let name = params["name"] as? String else {
                return rpcError(id: id, code: -32602, message: "Missing prompt name")
            }
            var arguments: [String: String] = [:]
            for (key, value) in params["arguments"] as? [String: Any] ?? [:] {
                guard let string = value as? String else {
                    return rpcError(id: id, code: -32602, message: "Argument \(key) must be a string")
                }
                arguments[key] = string
            }
            do {
                let result = try await prompts.get(name, arguments: arguments, identity: identity)
                return rpcResult(id: id, promptResult(result))
            } catch let error as PromptError {
                return rpcError(id: id, code: -32602, message: error.message)
            } catch {
                return rpcError(id: id, code: -32603, message: String(describing: error))
            }
        default:
            return rpcError(id: id, code: -32601, message: "Method not found")
        }
    }

    private func render(_ descriptor: PromptDescriptor) -> [String: Any] {
        [
            "name": descriptor.name,
            "title": descriptor.title,
            "description": descriptor.description,
            "arguments": descriptor.arguments.map {
                ["name": $0.name, "description": $0.description, "required": $0.required]
            },
        ]
    }

    private func promptResult(_ result: PromptResult) -> [String: Any] {
        [
            "description": result.description,
            "messages": result.messages.map {
                ["role": $0.role.rawValue, "content": ["type": "text", "text": $0.text]]
            },
        ]
    }

    private func render(_ descriptor: ToolDescriptor) -> [String: Any] {
        [
            "name": descriptor.name,
            "description": descriptor.description,
            "inputSchema": descriptor.inputSchema.anyValue,
        ]
    }

    private func render(_ descriptor: ResourceDescriptor) -> [String: Any] {
        [
            "uri": descriptor.uri,
            "name": descriptor.name,
            "description": descriptor.description,
            "mimeType": descriptor.mimeType,
        ]
    }

    private func render(_ contents: ResourceContents) -> [String: Any] {
        ["uri": contents.uri, "mimeType": contents.mimeType, "text": contents.text]
    }

    private func resourceNotFound(id: Any, uri: String, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": -32002, "message": message, "data": ["uri": uri]]]
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
