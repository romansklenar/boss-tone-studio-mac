import AppKit
import BossToneStudioCore
import Foundation
import os

// Runs Roland's BOSS TONE STUDIO for KATANA MkII web app natively on Apple Silicon.
//
//   BossToneStudio                   the app window
//   BossToneStudio --browser         serve only; open the printed URL in a browser (no file dialogs)
//   BossToneStudio --import-roland   (re)import the Librarian from Roland's app, then exit

setvbuf(stdout, nil, _IOLBF, 0)  // every log line reaches `make trace` and pipes at once

/// As Python's `sys.exit(message)`: the message on standard error, exit status 1.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func isFile(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
}

func importRoland(into dataDir: URL, locked: Bool) -> Never {
    guard locked else {
        fail("Quit the app first: it would overwrite the imported Librarian with the one it has open.")
    }
    guard FileManager.default.fileExists(atPath: RolandImport.prefs.path) else {
        fail("Roland's settings not found in \(RolandImport.prefs.path)")
    }
    do {
        try RolandImport.importLibrarian(dataDir: dataDir)
    } catch {
        fail("Import failed (\(error.localizedDescription))")
    }
    exit(0)
}

func startBridge(dataDir: URL) -> Bridge {
    let midi: CoreMIDIBackend?
    do {
        midi = try CoreMIDIBackend()
    } catch {
        log("CoreMIDI unavailable: \(error)")
        midi = nil
    }
    do {
        // `fs_exec`: the bridge lets only web links through, and they open in the user's browser.
        return try Bridge(dataDir: dataDir, midiBackend: midi) { url in
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    } catch {
        fail("Cannot start the bridge: \(error)")
    }
}

/// Serves the web app and the bridge on 127.0.0.1; returns the server, its port and the page's URL.
func serve(_ html: URL, _ bridge: Bridge) -> (HTTPServer, UInt16, URL) {
    let token = makeToken()
    // The router needs the port, which the server knows only once it listens.
    let slot = OSAllocatedUnfairLock<Router?>(initialState: nil)
    let server = HTTPServer { request in
        guard let router = slot.withLock({ $0 }) else { return .error(503) }
        return await router.handle(request)
    }
    let port: UInt16
    do {
        port = try server.start()
    } catch {
        bridge.removeTempDir()
        fail("\(error)")
    }
    slot.withLock { $0 = Router(port: port, token: token, htmlDir: html, dispatcher: bridge, proxy: Proxy()) }
    guard let page = URL(string: "http://127.0.0.1:\(port)/\(token)/index.html") else {
        bridge.removeTempDir()
        fail("no page URL for port \(port)")
    }
    return (server, port, page)
}

/// Ctrl-C in the terminal and `kill` reach `handler` on the main thread instead of ending the process at once.
func onTerminationSignals(_ handler: @escaping @MainActor @Sendable (Int32) -> Void) -> [DispatchSourceSignal] {
    [SIGINT, SIGTERM].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler(number) } }
        source.resume()
        return source
    }
}

let arguments = CommandLine.arguments.dropFirst()
let environment = ProcessInfo.processInfo.environment
let dataDir = AppPaths.dataDir(env: environment)
// Held, and so locked, until the process exits: one process per data folder.
let dataDirLock = DataDirLock.acquire(dataDir.appendingPathComponent("app.lock"))

if arguments.contains("--import-roland") { importRoland(into: dataDir, locked: dataDirLock != nil) }
guard dataDirLock != nil else { fail("Another instance already uses \(dataDir.path).") }

// The checkout this was built from, where `make roland-assets` puts Roland's web app.
let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
let resources = AppPaths.bundleResources(bundleURL: Bundle.main.bundleURL, resourceURL: Bundle.main.resourceURL)
let html = AppPaths.htmlDir(env: environment, bundleResources: resources, checkout: checkout)
guard isFile(html.appendingPathComponent("index.html")) else {
    fail("Roland's web app not found in \(html.path); run `make roland-assets` or set BTS_HTML_DIR.")
}
RolandImport.importOnce(dataDir: dataDir)  // before the page loads, so it opens on the imported Librarian

let bridge = startBridge(dataDir: dataDir)
let (server, port, page) = serve(html, bridge)

if arguments.contains("--browser") {
    print("Serving \(html.path)\nOpen \(page.absoluteString)")
    // Nothing else ends this mode: the temp folder goes, then the signal ends the process as it would have.
    let browserSignals = onTerminationSignals { number in
        bridge.removeTempDir()
        signal(number, SIG_DFL)
        raise(number)
    }
    withExtendedLifetime((server, browserSignals)) { RunLoop.main.run() }
    exit(0)
}

let delegate = AppDelegate(bridge: bridge, page: page, port: port)
// Through the close handshake, so the page takes the amp out of editor mode first.
let appSignals = onTerminationSignals { _ in NSApp.terminate(nil) }
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.run()
