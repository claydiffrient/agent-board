import Foundation

/// What a burst of user keystrokes does to the text sitting in a TUI prompt.
public enum PromptInputEffect: Equatable, Sendable {
    case dirties
    case submits
    case cancels
    case neutral
}

/// Classifies bytes on their way to the orchestrator PTY so the console can tell whether the
/// human has unsubmitted text in the prompt (SPEC §9.1). The input model belongs to Claude Code's
/// TUI, not to us, so every ambiguous sequence resolves to `.neutral` — which leaves an already
/// dirty prompt dirty, delaying a notice rather than overwriting what someone is typing.
public enum PromptInputClassifier {
    private static let escape: UInt8 = 0x1b
    private static let csiIntroducer: UInt8 = 0x5b
    private static let ss3Introducer: UInt8 = 0x4f
    private static let pasteStart: [UInt8] = Array("[200~".utf8)
    private static let pasteEnd: [UInt8] = Array("[201~".utf8)

    /// The last decisive effect in the burst wins: text typed after an Enter leaves the prompt dirty.
    public static func classify(_ bytes: ArraySlice<UInt8>) -> PromptInputEffect {
        var effect = PromptInputEffect.neutral
        var index = bytes.startIndex
        var insidePaste = false

        while index < bytes.endIndex {
            let byte = bytes[index]

            if insidePaste {
                if byte == escape, matches(pasteEnd, in: bytes, at: bytes.index(after: index)) {
                    insidePaste = false
                    index = bytes.index(index, offsetBy: pasteEnd.count + 1)
                } else {
                    effect = .dirties
                    index = bytes.index(after: index)
                }
                continue
            }

            if byte == escape {
                let next = bytes.index(after: index)
                if matches(pasteStart, in: bytes, at: next) {
                    insidePaste = true
                    effect = .dirties
                    index = bytes.index(index, offsetBy: pasteStart.count + 1)
                    continue
                }
                guard next < bytes.endIndex else {
                    effect = .cancels
                    index = next
                    continue
                }
                switch bytes[next] {
                case csiIntroducer:
                    index = endOfCSI(in: bytes, from: next)
                case ss3Introducer:
                    index = min(bytes.index(index, offsetBy: 3), bytes.endIndex)
                case 0x0d, 0x0a:
                    effect = .dirties
                    index = bytes.index(index, offsetBy: 2)
                default:
                    index = bytes.index(index, offsetBy: 2)
                }
                continue
            }

            switch byte {
            case 0x0d, 0x0a:
                effect = .submits
            case 0x03, 0x15:
                effect = .cancels
            case 0x00 ..< 0x20, 0x7f:
                break
            default:
                effect = .dirties
            }
            index = bytes.index(after: index)
        }

        return insidePaste ? .dirties : effect
    }

    private static func matches(_ pattern: [UInt8], in bytes: ArraySlice<UInt8>, at start: ArraySlice<UInt8>.Index) -> Bool {
        var index = start
        for expected in pattern {
            guard index < bytes.endIndex, bytes[index] == expected else { return false }
            index = bytes.index(after: index)
        }
        return true
    }

    /// A CSI sequence runs until a final byte in 0x40...0x7e; an unterminated one consumes the rest.
    private static func endOfCSI(in bytes: ArraySlice<UInt8>, from introducer: ArraySlice<UInt8>.Index) -> ArraySlice<UInt8>.Index {
        var index = bytes.index(after: introducer)
        while index < bytes.endIndex {
            let byte = bytes[index]
            index = bytes.index(after: index)
            if (0x40 ... 0x7e).contains(byte) { return index }
        }
        return bytes.endIndex
    }
}

/// Claude Code reads any single stdin read over 800 characters as a paste, and a pasted `/compact`
/// runs no command; the macOS PTY hands the reader about 1 KiB at a time, so one long write arrives
/// as several pastes (measured 2026-09-26, SPEC §2). Bursts this short, a pause apart, stay under
/// the limit even if a few coalesce into one read.
public enum PromptBursts {
    public static let maximumLength = 256
    public static let pause: Duration = .milliseconds(50)

    /// Splits on character boundaries, measuring in UTF-16 units as Claude Code does.
    public static func split(_ line: String) -> [String] {
        var bursts: [String] = []
        var current = ""
        var length = 0
        for character in line {
            let units = character.utf16.count
            if length + units > maximumLength, !current.isEmpty {
                bursts.append(current)
                current = ""
                length = 0
            }
            current.append(character)
            length += units
        }
        if !current.isEmpty { bursts.append(current) }
        return bursts
    }
}
