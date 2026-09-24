import Foundation

/// The MCP resource addresses of Agent Board's standing briefings. They live here rather than
/// beside the resource handler because the texts that tell a session how to get its briefing back
/// — the resume prompt, the orchestrator's own briefing — have to name uris the handler accepts.
///
/// Measured against Claude Code 2.1.272: a `claude --bg` session's client fetches `prompts/list`
/// during its handshake and never surfaces the result to the agent, and no route to `prompts/get`
/// is exposed to it at all. `resources/read` is the only one of the two an unattended session can
/// reach, so anything a worker must be able to fetch for itself is addressed here.
public enum BriefingResourceURI {
    public static let scheme = "briefing"

    /// The standing worker protocol, rendered for the caller's own task branch.
    public static let worker = "\(scheme)://worker"

    /// The orchestrator's launch briefing, composed from the project's current settings.
    public static let orchestrator = "\(scheme)://orchestrator"

    /// A rostered reviewer's spawn prompt, rebuilt from its recorded session.
    public static let reviewer = "\(scheme)://reviewer"
}
