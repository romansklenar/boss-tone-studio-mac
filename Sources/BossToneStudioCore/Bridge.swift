import Darwin
import Foundation
import os

/// The app window as the bridge needs it; there is none in `--browser` mode. The bridge calls these from connection
/// queues and from the exit fallback's task, never while it holds one of its own locks, so an implementation may hop
/// to the main thread and wait for it.
public protocol BridgeHost: AnyObject, Sendable {
    func closeWindow()
    /// `completion` gets the chosen path, or nil when the user cancelled. It must be called exactly once, from any
    /// thread, and may be called after this method has returned.
    func chooseFileToOpen(extensions: [String], completion: @escaping @Sendable (String?) -> Void)
    func chooseFileToSave(suggestedName: String, completion: @escaping @Sendable (String?) -> Void)
}

public protocol CommandDispatching: Sendable {
    /// Sorted, e.g. `app_storage2`.
    var commands: [String] { get }
    /// The page's answer; nil stands for `undefined`. A throw becomes the `500` the page raises as an error.
    func dispatch(_ command: String, _ args: [String]) throws -> String?
}

/// The text is the `500` body. Anything the page chose in it goes through `escaped`.
public struct BridgeError: Error, CustomStringConvertible, Equatable, LocalizedError {
    public let description: String

    public var errorDescription: String? { description }
}

/// The `$native` commands BOSS TONE STUDIO for KATANA MkII calls, as 0.1.1's Python bridge implemented them:
/// storage, files, dialogs, MIDI, an event queue the page polls, and the close handshake.
public final class Bridge: CommandDispatching {
    private struct Command: Sendable {
        let arguments: ClosedRange<Int>
        let run: @Sendable (Bridge, [String]) throws -> String?

        /// Without a count, any arguments are accepted and ignored.
        init(
            _ arguments: ClosedRange<Int> = 0...Int.max, _ run: @escaping @Sendable (Bridge, [String]) throws -> String?
        ) {
            self.arguments = arguments
            self.run = run
        }
    }

    private struct Closing {
        var host: BridgeHost?
        var exiting = false
        var fallback: Task<Void, Never>?
    }

    private static let maxQueuedEvents = 10_000  // they pile up only while no page polls

    private static let table: [String: Command] = [
        "app_ready": Command { _, _ in nil },
        "app_getevent": Command(0...0) { bridge, _ in bridge.popEvent() },
        "app_storage": Command(0...1) { bridge, args in try bridge.appStorage(args.first) },
        "app_storage2": Command(1...2) { bridge, args in try bridge.appStorage2(args[0], args.dropFirst().first) },
        "app_control": Command { _, _ in nil },  // 'indicator start|stop', 'set_window_size:…'
        "app_importfile": Command { _, _ in nil },
        "app_exportfile": Command { _, _ in nil },
        "app_exit": Command(0...0) { bridge, _ in
            bridge.appExit()
            return nil
        },
        "fs_separator": Command(0...0) { _, _ in "/" },
        "fs_path": Command(1...1) { bridge, args in bridge.path(args[0]) },
        "fs_exec": Command(1...1) { bridge, args in
            try bridge.exec(args[0])
            return nil
        },
        "fs_readString": Command(1...1) { bridge, args in try bridge.readString(args[0]) },
        "fs_writeString": Command(2...2) { bridge, args in
            try bridge.writeString(args[0], args[1])
            return nil
        },
        "fs_openfilename": Command(0...1) { bridge, args in
            try bridge.openFileName(filterJSON: args.first)
            return nil
        },
        "fs_savefilename": Command(2...2) { bridge, args in
            try bridge.saveFileName(args[0], extension: args[1])
            return nil
        },
        "midi_inendpoints": Command(0...0) { bridge, _ in bridge.midi.inputs() },
        "midi_outendpoints": Command(0...0) { bridge, _ in bridge.midi.outputs() },
        "midi_inconnect": Command(1...1) { bridge, args in
            bridge.midi.connectInput(args[0])
            return nil
        },
        "midi_outconnect": Command(1...1) { bridge, args in
            bridge.midi.connectOutput(args[0])
            return nil
        },
        "midi_indisconnect": Command { bridge, _ in
            bridge.midi.disconnectInput()
            return nil
        },
        "midi_outdisconnect": Command { bridge, _ in
            bridge.midi.disconnectOutput()
            return nil
        },
        "midi_send": Command(1...1) { bridge, args in
            try bridge.midi.send(args[0])
            return nil
        },
        "midi_panel": Command { _, _ in nil },
    ]

    /// `bts-XXXXXX` in the system's temporary folder, private to the user and resolved, as `fs_path` hands it out.
    public let tempDir: URL
    private let dataDir: URL
    private let storage2: Storage2
    private let files: FileAccess
    private let midi: MidiController
    private let openURL: @Sendable (URL) -> Void
    private let exitFallback: Duration
    private let events: OSAllocatedUnfairLock<[String]>
    private let closing = OSAllocatedUnfairLock(initialState: Closing())

    /// Creates the data folder if it is missing. `openURL` opens a web link in the user's browser.
    public init(
        dataDir: URL, midiBackend: MidiBackend?, exitFallback: Duration = .seconds(2),
        openURL: @escaping @Sendable (URL) -> Void
    ) throws {
        storage2 = try Storage2(dataDir: dataDir)
        guard let resolvedData = FileAccess.canonical(dataDir.path) else {
            throw BridgeError(description: "cannot resolve the data folder \(escaped(dataDir.path))")
        }
        self.dataDir = URL(fileURLWithPath: resolvedData, isDirectory: true)
        tempDir = try Self.makeTempDir()
        files = FileAccess(dataDir: self.dataDir, tempDir: tempDir)
        // The queue exists before the controller, which emits through it, and `self` does not yet.
        let events = OSAllocatedUnfairLock(initialState: [String]())
        self.events = events
        midi = MidiController(backend: midiBackend) { Bridge.enqueue(events, $0, $1, $2) }
        self.openURL = openURL
        self.exitFallback = exitFallback
    }

    public var host: BridgeHost? {
        get { closing.withLock { $0.host } }
        set { closing.withLock { $0.host = newValue } }
    }

    public var commands: [String] { Self.table.keys.sorted() }

    public func dispatch(_ command: String, _ args: [String]) throws -> String? {
        guard let entry = Self.table[command] else {
            // Without the quotes, so a name that passes the server's route check reads as it did in 0.1.1.
            log("unimplemented $$\(escaped(command).dropFirst().dropLast()) \(pyList(args))")
            return nil
        }
        if command != "app_getevent" { trace("->", "$$\(command)", args) }
        guard entry.arguments.contains(args.count) else {
            let (low, high) = (entry.arguments.lowerBound, entry.arguments.upperBound)
            let expected = low == high ? "\(high)" : "\(low) to \(high)"
            throw BridgeError(
                description: "$$\(command) takes \(expected) argument\(high == 1 ? "" : "s"), got \(args.count)")
        }
        return try entry.run(self, args)
    }

    /// Queues an event for the page to poll. MIDI events take the same path from CoreMIDI's threads, possibly while the
    /// controller holds its own lock, so it only appends under the queue's short lock: it never blocks on anything else
    /// and never calls into the controller or the host. (BTS_TRACE=1 also prints a line, before taking the lock.)
    public func emit(_ prop: String, _ kind: String, _ args: [String]) {
        Self.enqueue(events, prop, kind, args)
    }

    /// The window's close request. The page takes the amp out of editor mode first and then calls `$$app_exit`; until
    /// that has happened (or `exitFallback` has passed) closing is refused. True once the window is meant to go.
    public func windowShouldClose() -> Bool {
        enum Verdict { case close, waitForPage, askPage }
        let delay = exitFallback
        let verdict = closing.withLock { closing -> Verdict in
            if closing.host == nil { return .close }  // `appExit` is destroying it
            if closing.exiting { return .waitForPage }  // a second click while the page is still answering
            closing.exiting = true
            closing.fallback = Task { [weak self] in
                try? await Task.sleep(for: delay)
                if !Task.isCancelled { self?.appExit() }
            }
            return .askPage
        }
        if verdict == .askPage { emit("app", "command", ["exit"]) }
        return verdict == .close
    }

    /// The page's `$$app_exit`, or the fallback: disconnects MIDI and closes the window, once.
    public func appExit() {
        let (host, fallback) = closing.withLock { closing -> (BridgeHost?, Task<Void, Never>?) in
            closing.exiting = true
            defer {
                closing.host = nil
                closing.fallback = nil
            }
            return (closing.host, closing.fallback)
        }
        fallback?.cancel()
        midi.disconnectAll()
        host?.closeWindow()
    }

    public func removeTempDir() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private static func makeTempDir() throws -> URL {
        let template = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bts-XXXXXX").path
        var characters = Array(template.utf8CString)
        guard mkdtemp(&characters) != nil else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let created = String(decoding: characters.dropLast().map(UInt8.init(bitPattern:)), as: UTF8.self)
        guard let resolved = FileAccess.canonical(created) else {
            throw BridgeError(description: "cannot resolve the temporary folder \(escaped(created))")
        }
        return URL(fileURLWithPath: resolved, isDirectory: true)
    }

    private static func enqueue(
        _ events: OSAllocatedUnfairLock<[String]>, _ prop: String, _ kind: String, _ args: [String]
    ) {
        trace("<-", "\(prop).\(kind)", args)
        let event = ([prop, kind] + args).joined(separator: "\u{0C}")
        events.withLock { queue in
            queue.append(event)
            if queue.count > maxQueuedEvents { queue.removeFirst() }
        }
    }

    private func popEvent() -> String? {
        events.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }

    private func appStorage(_ data: String?) throws -> String? {
        let file = dataDir.appendingPathComponent("storage.json")
        guard let data else { return try readTextOrThrow(file) ?? "" }
        try writeAtomically(data, to: file)
        return nil
    }

    private func appStorage2(_ key: String, _ data: String?) throws -> String? {
        guard let data else { return try storage2.read(key) ?? "" }
        try storage2.write(key, data)
        return nil
    }

    private func path(_ location: String) -> String {
        switch location {
        case "temporary": tempDir.path + "/"
        case "library": dataDir.path + "/"
        default: ""
        }
    }

    /// The MkII only opens web pages (driver download, Roland links); nothing local is launched, and no link leads
    /// back to this Mac, where the page's own URLs would hand the browser its token. Roland's links name public sites
    /// without userinfo, which could make the browser read another host than Foundation does.
    private func exec(_ url: String) throws {
        guard url.hasPrefix("https://") || url.hasPrefix("http://"), let target = URL(string: url), target.user == nil,
            let host = target.host(percentEncoded: false), !Self.isThisMac(host)
        else { throw BridgeError(description: "refusing to open \(escaped(url))") }
        openURL(target)
    }

    /// An empty host, a `localhost` name, or any spelling a browser reads as a loopback or unspecified address:
    /// `inet_aton` takes `127.1` and `0x7f000001` as browsers do, and `::1`, `::` and `::ffff:127.0.0.1` end in one.
    private static func isThisMac(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        if name.isEmpty || name == "localhost" || name.hasSuffix(".localhost") { return true }
        let localFirstOctets: Set<UInt32> = [0, 127]
        var ipv4 = in_addr()
        if inet_aton(name, &ipv4) == 1 { return localFirstOctets.contains(UInt32(bigEndian: ipv4.s_addr) >> 24) }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, name, &ipv6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
        let mapped: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF]
        let embedsIPv4 = bytes[..<12].allSatisfy { $0 == 0 } || bytes[..<12].elementsEqual(mapped)
        return embedsIPv4 && localFirstOctets.contains(UInt32(bytes[12]))
    }

    private func readString(_ path: String) throws -> String {
        let file = try files.checkRead(path)
        guard let text = try readTextOrThrow(file) else {
            throw BridgeError(description: "\(escaped(path)) is not a file")
        }
        return text
    }

    private func writeString(_ path: String, _ text: String) throws {
        let file = try files.checkWrite(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeAtomically(text, to: file)
    }

    private func openFileName(filterJSON: String?) throws {
        var extensions: [String] = []
        if let filterJSON, !filterJSON.isEmpty {
            guard let decoded = try? JSONDecoder().decode([String].self, from: Data(filterJSON.utf8)) else {
                throw BridgeError(description: "invalid file filter \(escaped(filterJSON))")
            }
            extensions = decoded
        }
        guard let host = hostForDialog("openfilename") else { return }
        host.chooseFileToOpen(extensions: extensions) { [weak self] picked in
            guard let self else { return }
            answered("openfilename", picked ?? "", allow: files.allowOpen)
        }
    }

    private func saveFileName(_ name: String, extension ext: String) throws {
        // Appended to the chosen path, so it must not hold a "/".
        let isPlain = (1...10).contains(ext.utf8.count) && ext.utf8.allSatisfy(Self.isASCIIAlphanumeric)
        guard isPlain else { throw BridgeError(description: "refusing extension \(escaped(ext))") }
        guard let host = hostForDialog("savefilename") else { return }
        host.chooseFileToSave(suggestedName: "\(name).\(ext)") { [weak self] picked in
            guard let self else { return }
            let path = picked ?? ""
            let named = path.isEmpty || path.lowercased().hasSuffix(".\(ext.lowercased())") ? path : "\(path).\(ext)"
            answered("savefilename", named, allow: files.allowSave)
        }
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "a")...UInt8(ascii: "z"):
            true
        default: false
        }
    }

    private func hostForDialog(_ event: String) -> BridgeHost? {
        let host = self.host
        if host == nil { log("fs_\(event) needs the app window (not available in --browser mode)") }
        return host
    }

    /// The dialog's answer reaches the page as an `fs` event (the command itself has returned long before, as with
    /// Roland's shell). A chosen path is allowed first: the page reads or writes it as soon as it hears of it.
    private func answered(_ event: String, _ path: String, allow: (String) -> Void) {
        if !path.isEmpty { allow(path) }
        emit("fs", event, [path])
    }
}
