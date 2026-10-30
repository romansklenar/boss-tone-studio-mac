import AppKit
import BossToneStudioCore

/// One window; Cmd-Q, Cmd-W and the close button all go through the bridge's close handshake, and closing the window
/// quits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let bridge: Bridge
    private let page: URL
    private let port: UInt16
    private var window: WebWindow?
    /// `applicationShouldTerminate` answered `.terminateLater`: AppKit waits for a reply while the page takes the amp
    /// out of editor mode.
    private var terminateReplyOwed = false

    init(bridge: Bridge, page: URL, port: UInt16) {
        self.bridge = bridge
        self.page = page
        self.port = port
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let (mainMenu, windowMenu) = Self.menus()
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        let window = WebWindow(bridge: bridge, page: page, port: port)
        bridge.host = window
        window.onClose = { [weak self] in self?.windowClosed() }
        self.window = window
        window.show()
        NSApp.activate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if bridge.windowShouldClose() {
            terminateReplyOwed = false
            return .terminateNow
        }
        terminateReplyOwed = true
        return .terminateLater
    }

    /// The handshake is over and the window is closing: let the quit that was waiting for it finish.
    private func windowClosed() {
        guard terminateReplyOwed else { return }
        terminateReplyOwed = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge.removeTempDir()
    }

    /// The main menu and its Window menu. Without an Edit menu, copy, paste and select all would not reach the page's
    /// text fields; Close (Cmd-W) goes through `performClose(_:)` and so through the close handshake.
    private static func menus() -> (main: NSMenu, window: NSMenu) {
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

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let bar = NSMenu()
        for submenu in [app, edit, window] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            bar.addItem(item)
        }
        return (bar, window)
    }
}
