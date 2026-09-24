import AppKit
import Foundation

/// Env-gated diagnostic that writes the app's real main menu, and the windows a menu item opens, to
/// a JSON file and exits. There is no display on the machines this project is developed on and no
/// route into another process's menu bar — `osascript` is denied assistive access — so a test that
/// wants to know what the Help menu actually contains has to ask the app itself. `AGENTBOARD_E2E_REPO`
/// is the same shape: a launch argument nothing in the UI reaches.
enum MenuProbe {
    static let outputKey = "AGENTBOARD_MENU_PROBE"
    /// A Help-menu item title to fire twice, to see how many windows two invocations leave behind.
    static let invokeKey = "AGENTBOARD_MENU_PROBE_INVOKE"

    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment[outputKey] else { return }
        waitForMenu { menu in
            var report: [String: Any] = [
                "topLevel": menu.items.map(\.title),
                "helpMenuTitle": NSApp.helpMenu?.title ?? "",
                "help": describe(helpMenu(menu)),
                "menus": Dictionary(
                    menu.items.map { ($0.title, describe($0.submenu)) },
                    uniquingKeysWith: { first, _ in first }
                ),
            ]
            if let title = ProcessInfo.processInfo.environment[invokeKey] {
                report["invoked"] = title
                report["windowsAfterOne"] = invokeAndListWindows(title, in: helpMenu(menu))
                report["windowsAfterTwo"] = invokeAndListWindows(title, in: helpMenu(menu))
            }
            let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]))
                ?? Data("{}".utf8)
            try? data.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }

    private static func helpMenu(_ main: NSMenu) -> NSMenu? {
        NSApp.helpMenu ?? main.items.first { $0.title == "Help" }?.submenu
    }

    private static func describe(_ menu: NSMenu?) -> [[String: Any]] {
        (menu?.items ?? []).map { item in
            [
                "title": item.title,
                "keyEquivalent": item.keyEquivalent,
                "action": item.action.map(NSStringFromSelector) ?? "",
                "separator": item.isSeparatorItem,
                "hasView": item.view != nil,
                "enabled": item.isEnabled,
            ]
        }
    }

    private static func invokeAndListWindows(_ title: String, in menu: NSMenu?) -> [[String: Any]] {
        if let item = menu?.items.first(where: { $0.title == title }), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        }
        pump(turns: 60)
        return NSApp.windows.map { ["title": $0.title, "visible": $0.isVisible] }
    }

    /// SwiftUI installs the main menu during launch, so the probe has to outlast whatever else the
    /// app is doing on the main queue before that happens.
    private static func waitForMenu(_ body: @escaping (NSMenu) -> Void) {
        DispatchQueue.main.async {
            for _ in 0..<400 {
                if let menu = NSApp.mainMenu, !menu.items.isEmpty { return body(menu) }
                pump(turns: 1)
            }
            exit(2)
        }
    }

    private static func pump(turns: Int) {
        for _ in 0..<turns { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
}
