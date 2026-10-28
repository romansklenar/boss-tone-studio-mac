import AppKit
import BossToneStudioCore

/// One window; Cmd-Q and the close button both go through the bridge's close handshake, and closing the window quits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let bridge: Bridge
    private let page: URL
    private let port: UInt16
    private var window: WebWindow?

    init(bridge: Bridge, page: URL, port: UInt16) {
        self.bridge = bridge
        self.page = page
        self.port = port
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()
        let window = WebWindow(bridge: bridge, page: page, port: port)
        bridge.host = window
        self.window = window
        window.show()
        NSApp.activate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        bridge.windowShouldClose() ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge.removeTempDir()
    }

    /// Without an Edit menu, copy, paste and select all would not reach the page's text fields.
    private static func mainMenu() -> NSMenu {
        let app = NSMenu()
        app.addItem(
            withTitle: "Hide \(AppPaths.appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(
            withTitle: "Quit \(AppPaths.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let bar = NSMenu()
        for submenu in [app, edit] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            bar.addItem(item)
        }
        return bar
    }
}
