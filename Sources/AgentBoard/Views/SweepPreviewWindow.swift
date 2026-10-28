import AgentBoardCore
import AppKit
import Observation
import SwiftUI

/// SPEC §8.6. A `Window` rather than a `WindowGroup`, so choosing the menu item again brings the
/// open report forward instead of stacking a second one.
enum SweepPreviewScene {
    static let id = "leaked-agent-sweep"
    static let title = "Leaked-Agent Sweep Preview"
    static let menuTitle = "Preview Leaked-Agent Sweep…"
}

@Observable
@MainActor
final class SweepPreview {
    enum State: Equatable {
        case notRun
        case running
        case finished(AgentSweepReport)
        case unavailable
    }

    private(set) var state: State = .notRun
    private let supervisor: any WorkerSupervising

    init(supervisor: any WorkerSupervising) {
        self.supervisor = supervisor
    }

    func run() async {
        guard state != .running else { return }
        state = .running
        state = await supervisor.previewLeakedAgentSweep().map(State.finished) ?? .unavailable
    }

    var text: String {
        switch state {
        case .notRun, .running: return "Running the dry run…"
        case .unavailable: return "This build has no supervisor to ask, so there is nothing to preview."
        case let .finished(report): return report.lines.joined(separator: "\n")
        }
    }
}

struct SweepPreviewMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(SweepPreviewScene.menuTitle) { openWindow(id: SweepPreviewScene.id) }
    }
}

struct SweepPreviewWindow: View {
    let preview: SweepPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("""
            What the launch sweep would do now. Nothing was stopped: WOULD-STOP lines are the \
            sessions the next launch will stop, and every KEPT line says why it is left alone.
            """)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            ReadOnlyTextView(text: preview.text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Run Again") { _Concurrency.Task { await preview.run() } }
                    .disabled(preview.state == .running)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 320)
        .task { await preview.run() }
    }
}

/// A `Text` would do for display, but a human checking the report wants to select and copy lines.
private struct ReadOnlyTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }
}
