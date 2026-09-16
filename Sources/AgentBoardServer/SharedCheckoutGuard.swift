import Foundation

/// Keeps a co-resident agent from committing the tree instead of its own work.
///
/// `git commit -a`, or a bare `git commit` over a staged sibling's file, sweeps another task's
/// in-progress edits into this task's commit, and the per-task diff that acceptance reads is gone.
/// The deny is the same `PreToolUse` mechanism `IntegrationGuard` uses, which is the only thing
/// measured to stop an unattended `--permission-mode auto` worker.
public enum SharedCheckoutGuard {
    public static let commitToolName = "commit_my_work"

    public static func deniesCommit(toolName: String?, command: String?) -> Bool {
        IntegrationGuard.invokesGit("commit", toolName: toolName, command: command)
    }

    public static let commitReason = """
        Agent Board blocks `git commit` in a shared checkout: another agent is working in this same \
        tree, and a commit here would carry its unfinished edits under your task. Call the \
        \(commitToolName) MCP tool with your message instead. Agent Board commits exactly the files \
        you have written — it knows them from the locks your writes took — and tags the commit with \
        your task id so your work stays reviewable on its own.
        """
}
