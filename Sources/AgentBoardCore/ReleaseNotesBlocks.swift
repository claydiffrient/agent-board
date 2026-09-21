import Foundation

/// One rendered unit of a release's body, per SPEC §10. `AttributedString(markdown:)` parses block structure into
/// `presentationIntent` attributes that SwiftUI's `Text` does not consume — measured, a paragraph, a
/// two-item list and a heading come back as one run-on line with the markers stripped — so blocks
/// have to be split before rendering and only the inline markup handed to `AttributedString`.
public enum ReleaseNotesBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(indent: Int, text: String)
    case code(String)
}

public enum ReleaseNotesMarkdown {
    /// Splits a release body into blocks. Deliberately narrow: this reads the subset `RELEASES.md`
    /// is written in — headings, paragraphs, `-`/`*`/`+` bullets and fenced code — and anything it
    /// does not recognise stays a paragraph rather than being dropped.
    public static func blocks(_ markdown: String) -> [ReleaseNotesBlock] {
        var blocks: [ReleaseNotesBlock] = []
        var paragraph: [String] = []
        var bullet: (indent: Int, lines: [String])?
        var fence: [String]?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }
        func flushBullet() {
            guard let open = bullet else { return }
            blocks.append(.bullet(indent: open.indent, text: open.lines.joined(separator: " ")))
            bullet = nil
        }
        func flushAll() {
            flushParagraph()
            flushBullet()
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if fence != nil {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(fence!.joined(separator: "\n")))
                    fence = nil
                } else {
                    fence!.append(rawLine)
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushAll()
                fence = []
                continue
            }
            if trimmed.isEmpty {
                flushAll()
                continue
            }
            if let heading = heading(trimmed) {
                flushAll()
                blocks.append(heading)
                continue
            }
            if let marker = bulletText(rawLine) {
                flushAll()
                bullet = (marker.indent, [marker.text])
                continue
            }
            // An indented line under an open bullet continues it; markdown wraps that way and
            // `RELEASES.md` is written wrapped.
            if bullet != nil, rawLine.first == " " || rawLine.first == "\t" {
                bullet!.lines.append(trimmed)
                continue
            }
            flushBullet()
            paragraph.append(trimmed)
        }
        if let open = fence { blocks.append(.code(open.joined(separator: "\n"))) }
        flushAll()
        return blocks
    }

    private static func heading(_ line: String) -> ReleaseNotesBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: String(rest).trimmingCharacters(in: .whitespaces))
    }

    private static func bulletText(_ line: String) -> (indent: Int, text: String)? {
        let leading = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(leading)
        guard let marker = rest.first, marker == "-" || marker == "*" || marker == "+" else { return nil }
        let body = rest.dropFirst()
        guard body.first == " " else { return nil }
        return (leading / 2, String(body).trimmingCharacters(in: .whitespaces))
    }
}
