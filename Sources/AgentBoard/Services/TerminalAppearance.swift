import AppKit
import Foundation
import Observation
import SwiftTerm

struct TerminalColor: Codable, Hashable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ hex: UInt32) {
        self.init(red: UInt8((hex >> 16) & 0xff), green: UInt8((hex >> 8) & 0xff), blue: UInt8(hex & 0xff))
    }

    init(_ color: NSColor) {
        let srgb = color.usingColorSpace(.sRGB) ?? .black
        func byte(_ component: CGFloat) -> UInt8 { UInt8((max(0, min(1, component)) * 255).rounded()) }
        self.init(red: byte(srgb.redComponent), green: byte(srgb.greenComponent), blue: byte(srgb.blueComponent))
    }

    var hex: String { String(format: "#%02x%02x%02x", red, green, blue) }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    var swiftTermColor: SwiftTerm.Color {
        SwiftTerm.Color(red8: UInt16(red), green8: UInt16(green), blue8: UInt16(blue))
    }
}

/// How every Agent Board terminal looks: one app-wide choice, not per project. SPEC §10, Settings.
struct TerminalAppearance: Codable, Equatable {
    var fontFamily: String
    var fontSize: Double
    var foreground: TerminalColor
    var background: TerminalColor
    var cursor: TerminalColor
    var cursorText: TerminalColor
    var selectionBackground: TerminalColor
    var selectionForeground: TerminalColor
    /// The 16 ANSI colors. Colors 16–255 stay SwiftTerm's xterm cube.
    var palette: [TerminalColor]

    static let fontSizes: ClosedRange<Double> = 8...36

    /// A snapshot of Clay's Ghostty ("Night Owl", `ghostty +show-config`, 2026-10-19), not a live read.
    static let defaults = TerminalAppearance(
        fontFamily: "Monaspace Neon",
        fontSize: 12,
        foreground: TerminalColor(0xd6deeb),
        background: TerminalColor(0x011627),
        cursor: TerminalColor(0x7e57c2),
        cursorText: TerminalColor(0xffffff),
        selectionBackground: TerminalColor(0x5f7e97),
        selectionForeground: TerminalColor(0xdfe5ee),
        palette: [
            0x011627, 0xef5350, 0x22da6e, 0xaddb67, 0x82aaff, 0xc792ea, 0x21c7a8, 0xffffff,
            0x575656, 0xef5350, 0x22da6e, 0xffeb95, 0x82aaff, 0xc792ea, 0x7fdbca, 0xffffff,
        ].map(TerminalColor.init)
    )

    /// The stored family when it is installed, otherwise the monospaced system font.
    var font: NSFont {
        let size = CGFloat(fontSize)
        return NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func monospacedFamilies(_ fonts: NSFontManager = .shared) -> [String] {
        fonts.availableFontFamilies.filter { family in
            (fonts.availableMembers(ofFontFamily: family) ?? []).contains { member in
                member.count > 3 && ((member[3] as? NSNumber)?.uintValue ?? 0) & NSFontTraitMask.fixedPitchFontMask.rawValue != 0
            }
        }
    }
}

extension TerminalView {
    func apply(_ appearance: TerminalAppearance) {
        let font = appearance.font
        if self.font != font {
            self.font = font
        }
        nativeForegroundColor = appearance.foreground.nsColor
        nativeBackgroundColor = appearance.background.nsColor
        caretColor = appearance.cursor.nsColor
        caretTextColor = appearance.cursorText.nsColor
        selectedTextBackgroundColor = appearance.selectionBackground.nsColor
        selectedTextForegroundColor = appearance.selectionForeground.nsColor
        installColors(appearance.palette.map(\.swiftTermColor))
    }
}

/// The stored appearance, and every open terminal it is applied to, so an edit in Settings
/// repaints them all rather than only the next one opened.
@Observable
@MainActor
final class TerminalAppearanceStore {
    static let defaultsKey = "terminal.appearance"
    static let shared = TerminalAppearanceStore()

    var appearance: TerminalAppearance {
        didSet {
            guard appearance != oldValue else { return }
            defaults.set(try? JSONEncoder().encode(appearance), forKey: Self.defaultsKey)
            for terminal in terminals.allObjects {
                terminal.apply(appearance)
            }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let terminals = NSHashTable<TerminalView>.weakObjects()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = Self.load(defaults)
    }

    func attach(_ terminal: TerminalView) {
        terminals.add(terminal)
        terminal.apply(appearance)
    }

    func restoreDefaults() {
        appearance = .defaults
    }

    private static func load(_ defaults: UserDefaults) -> TerminalAppearance {
        guard let data = defaults.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(TerminalAppearance.self, from: data),
              stored.palette.count == 16
        else { return .defaults }
        return stored
    }
}
