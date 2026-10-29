import AppKit
import BossToneStudioCore
import UniformTypeIdentifiers
import WebKit

/// The app window: Roland's page in a web view that stays on the page's own origin, with native alerts and file
/// dialogs. The bridge calls the `BridgeHost` methods from its own threads; they hop to the main thread and return.
@MainActor
final class WebWindow: NSObject, BridgeHost, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
    private let bridge: Bridge
    private let port: Int
    private let window: NSWindow
    private let webView: WKWebView
    private var closed = false

    init(bridge: Bridge, page: URL, port: UInt16) {
        self.bridge = bridge
        self.port = Int(port)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = AppPaths.appName
        window.contentMinSize = NSSize(width: 1160, height: 700)
        window.isReleasedWhenClosed = false
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Only a click opens a window (which goes to the browser): no script, in the page or an embed, can on its own.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = MenuFreeWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = ProcessInfo.processInfo.environment["BTS_TRACE"] == "1"
        super.init()
        window.contentView = webView
        window.delegate = self
        webView.uiDelegate = self
        webView.navigationDelegate = self
        window.center()
        webView.load(URLRequest(url: page))
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: BridgeHost

    /// May come after AppKit has closed the window already: a second click once the page had answered.
    nonisolated func closeWindow() {
        DispatchQueue.main.async {
            guard !self.closed else { return }
            self.window.close()
        }
    }

    nonisolated func chooseFileToOpen(extensions: [String], completion: @escaping @Sendable (String?) -> Void) {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            let types = extensions.compactMap { UTType(filenameExtension: $0) }
            if !types.isEmpty { panel.allowedContentTypes = types }
            self.present(panel, completion: completion)
        }
    }

    /// The page chose `suggestedName`, so it only fills the name field; the user picks the folder.
    nonisolated func chooseFileToSave(suggestedName: String, completion: @escaping @Sendable (String?) -> Void) {
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedName
            panel.canCreateDirectories = true
            self.present(panel, completion: completion)
        }
    }

    private func present(_ panel: NSSavePanel, completion: @escaping @Sendable (String?) -> Void) {
        guard !closed else { return completion(nil) }
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.url?.path : nil)
        }
    }

    // MARK: NSWindowDelegate

    /// The close handshake: the page takes the amp out of editor mode first, then calls `$$app_exit`.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        bridge.windowShouldClose()
    }

    func windowWillClose(_ notification: Notification) {
        closed = true
    }

    // MARK: WKUIDelegate

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        present(Self.alert(message, buttons: ["OK"])) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        present(Self.alert(message, buttons: ["OK", "Cancel"])) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void
    ) {
        let alert = Self.alert(prompt, buttons: ["OK", "Cancel"])
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        present(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    /// No new windows: a clicked web link off the page's origin opens in the default browser, anything else is dropped.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, Self.isWeb(url), !isPage(url) { NSWorkspace.shared.open(url) }
        return nil
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(policy(for: navigationAction))
    }

    /// The window stays on the page's origin; other web pages go to the default browser. Subframes may load `https`
    /// only (the YouTube player), or stay empty (`about:`).
    private func policy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        guard action.targetFrame?.isMainFrame ?? true else {
            return ["https", "about"].contains(url.scheme?.lowercased()) ? .allow : .cancel
        }
        if isPage(url) { return .allow }
        if Self.isWeb(url) { NSWorkspace.shared.open(url) }
        return .cancel
    }

    /// `http://127.0.0.1:<port>`: the page's origin, whose URLs carry the token, so they never leave the window.
    private func isPage(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http" && url.host == "127.0.0.1" && url.port == port
    }

    private static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased())
    }

    private static func alert(_ message: String, buttons: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        for title in buttons { alert.addButton(withTitle: title) }
        return alert
    }

    /// As a sheet; once the window is gone, answered at once as if dismissed, since WebKit needs every answer.
    private func present(_ alert: NSAlert, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        guard !closed else { return completion(.cancel) }
        alert.beginSheetModal(for: window) { completion($0) }
    }
}

/// Roland's page turns the context menu off with an inline handler; WebKit's own menu stays away as well.
private final class MenuFreeWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
    }
}
