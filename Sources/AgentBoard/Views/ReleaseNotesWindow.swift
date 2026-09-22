import AgentBoardCore
import SwiftUI

/// What the release notes window shows, as a value. Every branch of `ReleaseNotesState` produces a
/// document — a build with no notes gets a sentence saying why rather than an empty window — so the
/// Help item never needs disabling and the window's contents are assertable without pixels.
struct ReleaseNotesDocument: Equatable {
    struct Section: Equatable {
        let version: ReleaseVersion
        let title: String
        let subtitle: String?
        let blocks: [ReleaseNotesBlock]
    }

    let notice: String?
    let sections: [Section]

    init(state: ReleaseNotesState) {
        switch state {
        case .unavailable:
            notice = """
            This build ships no release notes. Agent Board is running from the bare `AgentBoard` \
            binary; only the `.app` that `Scripts/bundle.sh` builds carries `RELEASES.md`.
            """
            sections = []
        case let .failed(message):
            notice = "Agent Board could not read its release notes. \(message)"
            sections = []
        case let .loaded(notes):
            notice = notes.entries.isEmpty ? "This build ships no release notes." : nil
            sections = notes.entries.map { entry in
                Section(
                    version: entry.version,
                    title: "\(entry.version)",
                    subtitle: Self.subtitle(entry, running: notes.appVersion),
                    blocks: ReleaseNotesMarkdown.blocks(entry.body)
                )
            }
        }
    }

    private static func subtitle(_ entry: ReleaseNotesEntry, running: ReleaseVersion) -> String? {
        var parts: [String] = []
        if let date = entry.date {
            parts.append(date.formatted(.dateTime.year().month(.wide).day()))
        }
        if entry.version == running { parts.append("this build") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// SPEC §10. The whole file in one scroll, newest release first. Three entries need no navigation;
/// at twenty this wants a version list beside a detail pane, because "what changed in the one I
/// skipped" becomes a scan rather than a read.
struct ReleaseNotesWindow: View {
    let state: ReleaseNotesState

    var body: some View {
        ScrollView {
            ReleaseNotesBody(document: ReleaseNotesDocument(state: state))
        }
        .frame(minWidth: 380, minHeight: 240)
    }
}

struct ReleaseNotesBody: View {
    let document: ReleaseNotesDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let notice = document.notice {
                Text(inlineMarkdown(notice))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(document.sections.enumerated()), id: \.element.version) { index, section in
                VStack(alignment: .leading, spacing: 10) {
                    if index > 0 { Divider().padding(.bottom, 4) }
                    Text(section.title)
                        .font(.title2.weight(.semibold))
                    if let subtitle = section.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                        ReleaseNotesBlockView(block: block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReleaseNotesBlockView: View {
    let block: ReleaseNotesBlock

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(inlineMarkdown(text))
                .font(level <= 3 ? .headline : .subheadline)
                .padding(.top, 6)
        case let .paragraph(text):
            Text(inlineMarkdown(text))
        case let .bullet(indent, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                Text(inlineMarkdown(text))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case let .code(text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// Inline markup only — bold, italics, code spans, links. Block structure is already split off by
/// `ReleaseNotesMarkdown`, and handing a whole block to `AttributedString` would drop its markers.
func inlineMarkdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnly)))
        ?? AttributedString(text)
}
