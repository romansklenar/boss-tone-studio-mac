import AppKit
import BossToneStudioCore
import UniformTypeIdentifiers
import WebKit

/// The app window: Roland's page in a web view that stays on the page's own origin, with native alerts and file
/// dialogs. The bridge calls the `BridgeHost` methods from its own threads; they hop to the main thread and return.
@MainActor
final class WebWindow: NSObject, BridgeHost, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
    private let bridge: Bridge
    private let page: URL
    private let port: Int
    private let window: NSWindow
    private let webView: WKWebView
    private var closed = false
    /// Called as the window closes, for a quit that waited for the close handshake.
    var onClose: (() -> Void)?

    init(bridge: Bridge, page: URL, port: UInt16) {
        self.bridge = bridge
        self.page = page
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
        webView.isInspectable = traceEnabled
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

    /// The page chose `suggestedName`, so it only fills the name field; the user picks the folder. For a type the Mac
    /// declares, the panel adds `ext` itself, so its question before replacing a file is about the file the page will
    /// write. No app declares `.tsl` or `.alb`, and for such a dynamic type the panel adds the extension again to a
    /// name that already ends with it (`name.tsl.tsl`), so it gets no type and saves the name as it stands.
    nonisolated func chooseFileToSave(
        suggestedName: String, extension ext: String, completion: @escaping @Sendable (String?) -> Void
    ) {
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedName
            if let type = UTType(filenameExtension: ext), !type.isDynamic { panel.allowedContentTypes = [type] }
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
        onClose?()
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

    /// No new windows: a clicked web link off this Mac opens in the default browser, anything else is dropped.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, isWebLinkOffThisMac(url) { NSWorkspace.shared.open(url) }
        return nil
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(policy(for: navigationAction))
    }

    /// Without its process (a crash, or WebKit ending it under memory pressure) the window would stay blank; the
    /// reloaded page reconnects to the stored amp by itself.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("the web page's process ended; reloading")
        webView.load(URLRequest(url: page))
    }

    /// The window stays on the page's origin; web links off this Mac go to the default browser, as `fs_exec`'s do, and
    /// anything else is dropped: another spelling of this Mac (`127.1`, `localhost`…) would hand the browser the token.
    /// Subframes may load `https` only (the YouTube player), or stay empty (`about:`).
    private func policy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        guard action.targetFrame?.isMainFrame ?? true else {
            return ["https", "about"].contains(url.scheme?.lowercased()) ? .allow : .cancel
        }
        if isPage(url) { return .allow }
        if isWebLinkOffThisMac(url) { NSWorkspace.shared.open(url) }
        return .cancel
    }

    /// `http://127.0.0.1:<port>`: the page's origin, whose URLs carry the token, so they never leave the window.
    private func isPage(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http" && url.host == "127.0.0.1" && url.port == port
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
