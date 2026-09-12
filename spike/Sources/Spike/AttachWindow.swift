import AppKit
import SwiftTerm

/// Blocks on the AppKit run loop until the window is closed. Returns after the app terminates its run loop.
@MainActor
func runAttachWindow(shortId: String, cwd: URL, onExit: @escaping (Int32) -> Void) {
    let session = TerminalWindowSession(title: "Agent Board — attach \(shortId)", onExit: onExit)
    session.run(executable: "/opt/homebrew/bin/claude", args: ["attach", shortId], cwd: cwd)
}

@MainActor
func runShellSmoke(cwd: URL) {
    let session = TerminalWindowSession(title: "Agent Board — shell smoke", onExit: { code in
        print("shell exited with \(code)")
    })
    session.run(executable: "/bin/zsh", args: ["-l"], cwd: cwd)
}

@MainActor
private final class TerminalWindowSession: NSObject, LocalProcessTerminalViewDelegate, NSWindowDelegate {
    private let window: NSWindow
    private let terminal: LocalProcessTerminalView
    private let onExit: (Int32) -> Void
    private var finished = false

    init(title: String, onExit: @escaping (Int32) -> Void) {
        self.onExit = onExit
        let contentRect = NSRect(x: 0, y: 0, width: 1100, height: 750)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()

        terminal = LocalProcessTerminalView(frame: contentRect)
        terminal.autoresizingMask = [.width, .height]
        terminal.nativeForegroundColor = .white
        terminal.nativeBackgroundColor = NSColor(calibratedRed: 0x1e / 255, green: 0x1e / 255, blue: 0x2e / 255, alpha: 1)
        terminal.caretColor = .systemGreen
        window.contentView = terminal
        super.init()
        window.delegate = self
        terminal.processDelegate = self
    }

    func run(executable: String, args: [String], cwd: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.mainMenu = buildMainMenu()

        terminal.startProcess(
            executable: executable,
            args: args,
            environment: childEnvironment(),
            execName: nil,
            currentDirectory: cwd.path
        )

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminal)
        app.activate(ignoringOtherApps: true)
        print("WINDOW=\(window.windowNumber)")
        if let seconds = ProcessInfo.processInfo.environment["SPIKE_AUTOCLOSE"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [window] in window.performClose(nil) }
        }
        app.run()

        if window.isVisible {
            window.close()
        }
    }

    private func childEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil || env["LANG"] == "" {
            env["LANG"] = "en_US.UTF-8"
        }
        return env.map { "\($0.key)=\($0.value)" }
    }

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        return mainMenu
    }

    private func finish(exitCode: Int32) {
        guard !finished else { return }
        finished = true
        onExit(exitCode)
        stopRunLoop()
    }

    /// `NSApp.stop` only takes effect once the run loop processes another event, so post one.
    private func stopRunLoop() {
        NSApp.stop(nil)
        let wake = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        )
        if let wake {
            NSApp.postEvent(wake, atStart: false)
        }
    }

    private func terminateChildAndReap() -> Int32 {
        let pid = terminal.process.shellPid
        guard terminal.process.running, pid > 0 else { return -1 }
        terminal.terminate()

        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let reaped = waitpid(pid, &status, WNOHANG)
            if reaped == pid { return decodeWaitStatus(status) }
            if reaped < 0 { return -1 }
            usleep(20_000)
        }
        kill(pid, SIGKILL)
        if waitpid(pid, &status, 0) == pid { return decodeWaitStatus(status) }
        return -1
    }

    private func decodeWaitStatus(_ status: Int32) -> Int32 {
        let low = status & 0x7f
        if low == 0 { return (status >> 8) & 0xff }
        return 128 + low
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        MainActor.assumeIsolated {
            guard !title.isEmpty else { return }
            window.title = title
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            finish(exitCode: exitCode ?? -1)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finish(exitCode: terminateChildAndReap())
    }
}
