import AgentBoardCore
import AgentBoardServer
import Foundation

/// Serves the standing texts a session may need back after its opening prompt has fallen out of
/// context. Every prompt renders through the same function the push path calls, so a prompt and
/// the text a session was handed at spawn cannot say different things.
///
/// This is additive: a wind-down order still reaches a busy worker through the `PreToolUse` deny
/// and an idle one through a resume. A worker that is not asking for anything cannot be reached
/// by a prompt.
public struct BriefingPromptHandler: PromptHandler {
    public init() {}

    public static let windDownOrder = "wind_down_order"
    public static let workerProtocol = "worker_protocol"

    public static let descriptors: [PromptDescriptor] = [
        PromptDescriptor(
            name: windDownOrder,
            title: "Wind-down order",
            description: "The full text of Agent Board's wind-down order: commit, acknowledge, stop. "
                + "Fetch it when you were handed a shortened or truncated version of the order and need the steps verbatim.",
            arguments: [
                PromptArgumentDescriptor(
                    name: "via",
                    description: "How the order reached the worker: `hook` (a blocked tool call carried it) or `resume`.",
                    required: true
                ),
                PromptArgumentDescriptor(
                    name: "reason",
                    description: "The reason the human gave for winding down, if one was given.",
                    required: false
                ),
            ]
        ),
        PromptDescriptor(
            name: workerProtocol,
            title: "Worker protocol",
            description: "The standing How to work and When you are done sections a worker is spawned with — "
                + "worktree rules, when to search notes, and the completion protocol. "
                + "Fetch it after a resume or a compaction, when the original instructions are no longer in context.",
            arguments: [
                PromptArgumentDescriptor(
                    name: "branch",
                    description: "The branch this worker is on, as it appears in the worktree rule.",
                    required: true
                ),
            ]
        ),
    ]

    public func prompts(for identity: TokenIdentity) async -> [PromptDescriptor] {
        Self.descriptors
    }

    public func get(_ name: String, arguments: [String: String], identity: TokenIdentity) async throws -> PromptResult {
        switch name {
        case Self.windDownOrder:
            let via = try Self.required("via", in: arguments, for: name)
            guard let delivery = ShutdownOrder.Delivery(rawValue: via) else {
                let allowed = ShutdownOrder.Delivery.allCases.map(\.rawValue).joined(separator: ", ")
                throw PromptError("Argument `via` must be one of: \(allowed).")
            }
            return PromptResult(
                description: "Agent Board's wind-down order, as delivered by \(via).",
                messages: [PromptMessage(text: ShutdownOrder.windDownOrder(reason: arguments["reason"], via: delivery))]
            )
        case Self.workerProtocol:
            let branch = try Self.required("branch", in: arguments, for: name)
            return PromptResult(
                description: "The standing worker protocol for branch \(branch).",
                messages: [PromptMessage(text: OpeningPrompt.workingProtocol(branch: branch))]
            )
        default:
            throw PromptError("Unknown prompt: \(name).")
        }
    }

    private static func required(_ argument: String, in arguments: [String: String], for prompt: String) throws -> String {
        guard let value = arguments[argument], !value.isEmpty else {
            throw PromptError("Prompt \(prompt) requires the argument `\(argument)`.")
        }
        return value
    }
}
