import AgentBoardCore
import SwiftUI

/// One of the two buttons that sit side by side on a session. They were `terminal` next to
/// `apple.terminal` — one stroked terminal window twice — until the symbols were split here, so
/// `symbol` is the whole separation and `SessionActionButtonsTests` pins both values.
struct SessionAction: Equatable {
    let symbol: String
    let title: String
    let accessibilityLabel: String

    static let attach = SessionAction(
        symbol: "bubble.left.fill",
        title: "Agent",
        accessibilityLabel: "Attach to agent session"
    )

    /// `apple.terminal` is also `WorktreeShellAvailability.symbol` for `.ready`, so the button and
    /// the window it opens show the same glyph.
    static let worktreeShell = SessionAction(
        symbol: "apple.terminal",
        title: "Shell",
        accessibilityLabel: "Open shell in worktree"
    )
}

/// The attach and worktree-shell pair, monochrome and unstyled at both call sites.
///
/// `showsTitle` is the only difference between them: the Status table's Actions column is
/// width-constrained and truncates a title to `Ag…`, so it takes `false`; the task inspector's
/// session row is not and takes `true`. The labels are what names these buttons for VoiceOver,
/// which in the Status column is the only thing that does.
struct SessionActionButtons: View {
    let session: AgentSession
    let showsTitle: Bool
    var attach: SessionAction = .attach
    var worktreeShell: SessionAction = .worktreeShell

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Button {
                openWindow(id: "terminal", value: session.sessionId)
            } label: {
                label(attach)
            }
            .accessibilityLabel(attach.accessibilityLabel)
            .accessibilityHint("Opens this agent's live Claude session in a terminal window.")
            .help("Attach to this agent's own Claude session")

            Button {
                openWindow(id: "worktree-shell", value: session.sessionId)
            } label: {
                label(worktreeShell)
            }
            .accessibilityLabel(worktreeShell.accessibilityLabel)
            .accessibilityHint(WorktreeShellAvailability.buttonHelp(session))
            .disabled(!WorktreeShellAvailability.canOpen(session))
            .help(WorktreeShellAvailability.buttonHelp(session))
        }
    }

    @ViewBuilder
    private func label(_ action: SessionAction) -> some View {
        if showsTitle {
            Label(action.title, systemImage: action.symbol)
        } else {
            Image(systemName: action.symbol)
        }
    }
}
