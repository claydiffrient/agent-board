import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOCore

final class SpikeServer: Sendable {
    private let token: String
    private let log: EventLog
    private let runState = RunState()

    init(token: String, log: EventLog) {
        self.token = token
        self.log = log
    }

    func start() async throws -> Int {
        let (ports, portSink) = AsyncStream.makeStream(of: Int.self)
        var logger = Logger(label: "spike-server")
        logger.logLevel = .warning
        let app = Application(
            router: buildRouter(),
            configuration: .init(address: .hostname("127.0.0.1", port: 0), serverName: "agent-board-spike"),
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
        await runState.set(task)
        for await port in ports where port != 0 {
            return port
        }
        try await task.value
        throw ServerError.failedToBind
    }

    func stop() async {
        await runState.cancel()
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
        guard request.uri.queryParameters["token"].map(String.init) == token else {
            return Response(status: .unauthorized)
        }
        let body = try await request.body.collect(upTo: 1 << 20)
        let payload = (try? JSONSerialization.jsonObject(with: Data(body.readableBytesView))) as? [String: Any] ?? [:]
        await log.record(.hook(
            event: payload["hook_event_name"] as? String ?? "",
            sessionId: payload["session_id"] as? String ?? "",
            transcriptPath: payload["transcript_path"] as? String
        ))
        return jsonResponse(status: .ok, body: [String: Any]())
    }

    @Sendable
    private func handleMCP(request: Request, context: BasicRequestContext) async throws -> Response {
        guard request.headers[.authorization] == "Bearer \(token)" else {
            return Response(status: .unauthorized)
        }
        let body = try await request.body.collect(upTo: 4 << 20)
        let parsed = try? JSONSerialization.jsonObject(with: Data(body.readableBytesView))
        let messages: [[String: Any]]
        let isBatch: Bool
        switch parsed {
        case let single as [String: Any]:
            messages = [single]
            isBatch = false
        case let batch as [[String: Any]]:
            messages = batch
            isBatch = true
        default:
            return jsonResponse(
                status: .badRequest,
                body: rpcError(id: NSNull(), code: -32700, message: "Parse error")
            )
        }

        var responses: [[String: Any]] = []
        for message in messages {
            if let response = await dispatch(message) {
                responses.append(response)
            }
        }
        guard !responses.isEmpty else { return Response(status: .accepted) }

        var response = isBatch
            ? jsonResponse(status: .ok, body: responses)
            : jsonResponse(status: .ok, body: responses[0])
        if messages.contains(where: { $0["method"] as? String == "initialize" }) {
            response.headers[HTTPField.Name("Mcp-Session-Id")!] = UUID().uuidString
        }
        return response
    }

    private func dispatch(_ message: [String: Any]) async -> [String: Any]? {
        guard let method = message["method"] as? String else { return nil }
        await log.record(.mcpRequest(method: method))
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let supported = ["2024-11-05", "2025-03-26", "2025-06-18"]
            return rpcResult(id: id, [
                "protocolVersion": supported.contains(requested) ? requested : "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "agent-board-spike", "version": "0.0.1"],
            ])
        case "ping":
            return rpcResult(id: id, [String: Any]())
        case "tools/list":
            return rpcResult(id: id, ["tools": [pingToolDescriptor]])
        case "tools/call":
            guard params["name"] as? String == "agent_board_ping" else {
                return rpcError(id: id, code: -32602, message: "Unknown tool")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            await log.record(.mcpToolCall(name: "agent_board_ping", arguments: compactJSON(arguments)))
            let text = "pong from agent board: \(arguments["message"] as? String ?? "")"
            return rpcResult(id: id, [
                "content": [["type": "text", "text": text]],
                "isError": false,
            ])
        default:
            return rpcError(id: id, code: -32601, message: "Method not found")
        }
    }

    private var pingToolDescriptor: [String: Any] {
        [
            "name": "agent_board_ping",
            "description": "Ping Agent Board. Returns a pong containing the message you sent. Call this once when asked to verify connectivity.",
            "inputSchema": [
                "type": "object",
                "properties": ["message": ["type": "string"]],
                "required": ["message"],
            ],
        ]
    }

    private func rpcResult(id: Any, _ result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func rpcError(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func compactJSON(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func jsonResponse(status: HTTPResponse.Status, body: Any) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}

enum ServerError: Error {
    case failedToBind
}

private actor RunState {
    private var task: Task<Void, Error>?

    func set(_ task: Task<Void, Error>) {
        self.task = task
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

func runServerSmoke(token: String) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let server = SpikeServer(token: token, log: EventLog())
    let port = try await server.start()
    print("PORT=\(port)")
    while true {
        try await Task.sleep(for: .seconds(3600))
    }
}
