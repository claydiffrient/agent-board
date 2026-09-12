import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let scratch = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-claydiffrient-PersonalProjects-agent-board/239dbafb-cbd2-446d-ae6c-6445de211cbe/scratchpad")
let fixtureRepo = scratch.appendingPathComponent("m0-repo")
let configDir = scratch.appendingPathComponent("m0-config")

enum Mode { case full, shell, attachOnly(String), noAttach, serve(String) }

func parseMode() -> Mode {
    let args = Array(CommandLine.arguments.dropFirst())
    switch args.first {
    case "shell": return .shell
    case "attach": return .attachOnly(args.dropFirst().first ?? "")
    case "no-attach": return .noAttach
    case "serve": return .serve(args.dropFirst().first ?? "t")
    default: return .full
    }
}

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
}

func sessionAlive(_ sessionId: String) -> AgentInfo? {
    let rows = (try? Spawner.listAgents()) ?? []
    return rows.first { $0.sessionId?.lowercased() == sessionId.lowercased() }
}

let workerPrompt = """
You are a connectivity probe. Do exactly this, in order, then stop:
1. Run the shell command `ls` in the current directory.
2. Call the MCP tool `agent_board_ping` with message "m0". If the tool is not in your tool list, say so verbatim: "agent_board_ping is not available".
3. Reply with one line: "probe finished".
Do not do anything else.
"""

struct Phase1Result {
    var server: SpikeServer
    var spawned: SpawnedSession
}

func runPhase1() async -> Phase1Result? {
    let log = EventLog()
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let server = SpikeServer(token: token, log: log)
    let port: Int
    do { port = try await server.start() } catch { print("server failed: \(error)"); return nil }
    print("server listening on 127.0.0.1:\(port)")

    let plan = SpawnPlan(port: port, token: token, cwd: fixtureRepo, name: "m0-probe",
                         configId: UUID(), prompt: workerPrompt, configDir: configDir)
    let spawned: SpawnedSession
    do { spawned = try Spawner.spawnBackground(plan) } catch { print("spawn failed: \(error)"); return nil }
    print("spawned short=\(spawned.shortId) session=\(spawned.sessionId)")
    print("settings: \(spawned.settingsPath.path)\nmcp:      \(spawned.mcpConfigPath.path)")

    let sid = spawned.sessionId.lowercased()
    func hook(_ name: String, timeout: Double) async -> Bool {
        await log.first(where: { if case .hook(name, let s, _) = $0 { return s.lowercased() == sid }; return false }, timeout: timeout) != nil
    }

    check("(1) SessionStart hook reached server", await hook("SessionStart", timeout: 90))
    check("(1) PostToolUse hook reached server", await hook("PostToolUse", timeout: 120))

    let toolsList = await log.first(where: { if case .mcpRequest("tools/list") = $0 { return true }; return false }, timeout: 30)
    check("(2) session requested tools/list over HTTP MCP", toolsList != nil)

    let toolCall = await log.first(where: { if case .mcpToolCall = $0 { return true }; return false }, timeout: 120)
    check("(2) session called agent_board_ping", toolCall != nil, toolCall.map { "\($0)" } ?? "")

    check("(1) Stop hook reached server", await hook("Stop", timeout: 120))

    let events = await log.events
    print("observed \(events.count) events total")
    return Phase1Result(server: server, spawned: spawned)
}

func spinUntil(_ done: () -> Bool) {
    while !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}

func runFull(attach: Bool) {
    var phase1: Phase1Result??
    Task.detached { let r = await runPhase1(); DispatchQueue.main.async { phase1 = .some(r) } }
    spinUntil { phase1 != nil }
    guard let result = phase1! else { exit(1) }

    guard attach else {
        print("skipping attach; session \(result.spawned.shortId) left running for manual inspection")
        return
    }

    print("opening SwiftTerm window for `claude attach \(result.spawned.shortId)`; close the window to continue")
    var exitCode: Int32 = -1
    MainActor.assumeIsolated {
        runAttachWindow(shortId: result.spawned.shortId, cwd: fixtureRepo) { exitCode = $0 }
    }
    print("attach process exited with \(exitCode)")
    Thread.sleep(forTimeInterval: 1)
    let alive = sessionAlive(result.spawned.sessionId)
    check("(3) background session survived detach", alive != nil,
          alive.map { "state=\($0.state ?? "?") status=\($0.status ?? "?")" } ?? "not listed")
    print("cleanup: claude stop \(result.spawned.shortId) && claude rm \(result.spawned.shortId)")
}

switch parseMode() {
case .shell:
    MainActor.assumeIsolated { runShellSmoke(cwd: fixtureRepo) }
case .attachOnly(let id):
    MainActor.assumeIsolated {
        runAttachWindow(shortId: id, cwd: fixtureRepo) { print("attach exited \($0)") }
    }
case .noAttach:
    runFull(attach: false)
case .serve(let token):
    Task.detached { try await runServerSmoke(token: token) }
    spinUntil { false }
case .full:
    runFull(attach: true)
}
