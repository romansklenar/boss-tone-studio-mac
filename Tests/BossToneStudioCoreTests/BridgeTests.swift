import Foundation
import Testing
import os

@testable import BossToneStudioCore

/// The form feed (`\f`) the page splits events on.
private let formFeed = "\u{0C}"

/// The app window. Dialogs answer inside the call unless a test holds them back, which also proves that the bridge
/// holds none of its locks while it calls the host: they are not reentrant.
private final class FakeHost: BridgeHost {
    private struct State {
        var closeCount = 0
        var openRequests: [[String]] = []
        var saveRequests: [[String]] = []  // the suggested name and the extension
        var openAnswer: String?
        var saveAnswer: String?
        var held: [@Sendable (String?) -> Void]?  // non-nil: dialogs wait for `answerHeldDialog`
    }

    private let state: OSAllocatedUnfairLock<State>
    private let closed = DispatchSemaphore(value: 0)

    init(openAnswer: String? = nil, saveAnswer: String? = nil, holdingDialogs: Bool = false) {
        state = OSAllocatedUnfairLock(
            initialState: State(openAnswer: openAnswer, saveAnswer: saveAnswer, held: holdingDialogs ? [] : nil))
    }

    var closeCount: Int { state.withLock { $0.closeCount } }
    var openRequests: [[String]] { state.withLock { $0.openRequests } }
    var saveRequests: [[String]] { state.withLock { $0.saveRequests } }

    var saveAnswer: String? {
        get { state.withLock { $0.saveAnswer } }
        set { state.withLock { $0.saveAnswer = newValue } }
    }

    func waitForClose(seconds: Double) -> Bool {
        closed.wait(timeout: .now() + seconds) == .success
    }

    func answerHeldDialog(with path: String?) {
        let completion = state.withLock { $0.held?.removeFirst() }
        completion?(path)
    }

    func closeWindow() {
        state.withLock { $0.closeCount += 1 }
        closed.signal()
    }

    func chooseFileToOpen(extensions: [String], completion: @escaping @Sendable (String?) -> Void) {
        state.withLock { $0.openRequests.append(extensions) }
        answer(completion) { $0.openAnswer }
    }

    func chooseFileToSave(
        suggestedName: String, extension ext: String, completion: @escaping @Sendable (String?) -> Void
    ) {
        state.withLock { $0.saveRequests.append([suggestedName, ext]) }
        answer(completion) { $0.saveAnswer }
    }

    private func answer(_ completion: @escaping @Sendable (String?) -> Void, with pick: @Sendable (State) -> String?) {
        let path: String?? = state.withLock { state in
            guard state.held != nil else { return .some(pick(state)) }
            state.held?.append(completion)
            return .none
        }
        if let path { completion(path) }
    }
}

/// One listed `KATANA` port that remembers what the bridge asked of it.
private final class FakeMidiBackend: MidiBackend {
    private struct State {
        var calls: [String] = []
        var sent: [[UInt8]] = []
        var onMessage: (@Sendable ([UInt8]) -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var calls: [String] { state.withLock { $0.calls } }
    var sent: [[UInt8]] { state.withLock { $0.sent } }

    func fireMessage(_ message: [UInt8]) {
        state.withLock { $0.onMessage }?(message)
    }

    func sourceNames() -> [String] { ["KATANA"] }
    func destinationNames() -> [String] { ["KATANA"] }

    func connectInput(named name: String, onMessage: @escaping @Sendable ([UInt8]) -> Void) throws {
        state.withLock {
            $0.calls.append("connectInput \(name)")
            $0.onMessage = onMessage
        }
    }

    func disconnectInput() {
        state.withLock {
            $0.calls.append("disconnectInput")
            $0.onMessage = nil
        }
    }

    func connectOutput(named name: String) throws {
        state.withLock { $0.calls.append("connectOutput \(name)") }
    }

    func disconnectOutput() {
        state.withLock { $0.calls.append("disconnectOutput") }
    }

    func send(_ message: [UInt8]) throws {
        state.withLock { $0.sent.append(message) }
    }

    func onSetupChanged(_ handler: @escaping @Sendable () -> Void) {}
}

private final class OpenedURLs: Sendable {
    private let urls = OSAllocatedUnfairLock(initialState: [URL]())

    var all: [URL] { urls.withLock { $0 } }

    func record(_ url: URL) { urls.withLock { $0.append(url) } }
}

/// A bridge over a fresh data folder (not created yet, as on a first launch) that is wound down afterwards: the
/// fallback timer cancelled and the temp folder removed.
private func withBridge<T>(
    midi: MidiBackend? = nil, host: BridgeHost? = nil, exitFallback: Duration = .seconds(60),
    opened: OpenedURLs = OpenedURLs(),
    _ body: (Bridge, URL) throws -> T
) throws -> T {
    try withTemporaryFolder { root in
        let data = root.appendingPathComponent("data")
        let bridge = try Bridge(dataDir: data, midiBackend: midi, exitFallback: exitFallback) { opened.record($0) }
        bridge.host = host
        defer {
            bridge.appExit()
            bridge.removeTempDir()
        }
        return try body(bridge, data)
    }
}

private func call(_ bridge: Bridge, _ command: String, _ args: String...) throws -> String? {
    try bridge.dispatch(command, args)
}

@Test func theCommandTableMatchesWhatTheMkIIAppCalls() throws {
    let expected = [
        "app_control", "app_exit", "app_exportfile", "app_getevent", "app_importfile", "app_ready", "app_storage",
        "app_storage2", "fs_exec", "fs_openfilename", "fs_path", "fs_readString", "fs_savefilename", "fs_separator",
        "fs_writeString", "midi_inconnect", "midi_indisconnect", "midi_inendpoints", "midi_outconnect",
        "midi_outdisconnect", "midi_outendpoints", "midi_panel", "midi_send",
    ]
    try withBridge { bridge, _ throws in
        #expect(bridge.commands.count == 23 && !bridge.commands.contains("app_startevent"))
        #expect(bridge.commands == expected.sorted())
    }
}

@Test func theNativeScriptPollsForEventsBecauseThereIsNoStartevent() throws {
    try withBridge { bridge, _ throws in
        #expect(bridge.commands.contains("app_getevent"))
        #expect(!bridge.commands.contains("app_startevent"))
    }
}

@Test func anUnknownCommandAnswersNothing() throws {
    try withBridge { bridge, _ throws in
        #expect(try call(bridge, "app_startevent", "x") == nil)
        #expect(try call(bridge, "app_getevent") == nil)
    }
}

@Test func wrongArgumentCountsThrow() throws {
    let wrong: [(command: String, args: [String])] = [
        ("app_storage2", []), ("app_storage2", ["a", "b", "c"]), ("app_storage", ["a", "b"]),
        ("app_getevent", ["x"]), ("app_exit", ["x"]), ("fs_separator", ["x"]), ("fs_path", []),
        ("fs_path", ["temporary", "x"]), ("fs_exec", []), ("fs_readString", []), ("fs_writeString", ["a"]),
        ("fs_openfilename", ["[]", "x"]), ("fs_savefilename", ["name"]), ("fs_savefilename", ["a", "b", "c"]),
        ("midi_inendpoints", ["x"]), ("midi_outendpoints", ["x"]), ("midi_inconnect", []),
        ("midi_outconnect", ["a", "b"]), ("midi_send", []),
    ]
    try withBridge { bridge, _ throws in
        for (command, args) in wrong {
            #expect(throws: BridgeError.self, "\(command) \(args)") { try bridge.dispatch(command, args) }
        }
        #expect(throws: BridgeError(description: "$$app_storage2 takes 1 to 2 arguments, got 3")) {
            try bridge.dispatch("app_storage2", ["a", "b", "c"])
        }
        #expect(throws: BridgeError(description: "$$fs_path takes 1 argument, got 0")) {
            try bridge.dispatch("fs_path", [])
        }
    }
}

@Test func someCommandsIgnoreTheirArguments() throws {
    try withBridge(midi: FakeMidiBackend()) { bridge, _ throws in
        for command in [
            "app_ready", "app_control", "app_importfile", "app_exportfile", "midi_panel", "midi_indisconnect",
            "midi_outdisconnect",
        ] {
            #expect(try bridge.dispatch(command, []) == nil, "\(command)")
            #expect(try bridge.dispatch(command, ["indicator start", "x"]) == nil, "\(command)")
        }
    }
}

@Test func fsSeparatorIsASlash() throws {
    try withBridge { bridge, _ throws in #expect(try call(bridge, "fs_separator") == "/") }
}

@Test func fsPathEndsWithASlash() throws {
    try withBridge { bridge, data throws in
        #expect(try call(bridge, "fs_path", "temporary") == bridge.tempDir.path + "/")
        #expect(try call(bridge, "fs_path", "library") == onDisk(data.path) + "/")
        #expect(try call(bridge, "fs_path", "x") == "")
    }
}

@Test func theTempFolderIsPrivateCanonicalAndRemovedOnRequest() throws {
    try withBridge { bridge, _ throws in
        let temp = bridge.tempDir
        #expect(temp.lastPathComponent.hasPrefix("bts-"))
        #expect(temp.path == onDisk(temp.path))
        #expect(temp.deletingLastPathComponent().path == onDisk(NSTemporaryDirectory()))
        let permissions = try FileManager.default.attributesOfItem(atPath: temp.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
        bridge.removeTempDir()
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }
}

@Test func eventsComeOutOldestFirstWithTheirFieldsSeparated() throws {
    try withBridge { bridge, _ throws in
        bridge.emit("midi", "message", ["F07EF7", "1700000000000"])
        bridge.emit("app", "command", ["exit"])
        #expect(try call(bridge, "app_getevent") == "midi\(formFeed)message\(formFeed)F07EF7\(formFeed)1700000000000")
        #expect(try call(bridge, "app_getevent") == "app\(formFeed)command\(formFeed)exit")
        #expect(try call(bridge, "app_getevent") == nil)
    }
}

@Test func eventsAreCappedAtTenThousand() throws {
    try withBridge { bridge, _ throws in
        for number in 1...10_001 { bridge.emit("test", "n", [String(number)]) }
        #expect(try call(bridge, "app_getevent") == "test\(formFeed)n\(formFeed)2")
        var popped = 1
        var last: String?
        while let event = try call(bridge, "app_getevent") {
            popped += 1
            last = event
        }
        #expect(popped == 10_000)
        #expect(last == "test\(formFeed)n\(formFeed)10001")
    }
}

@Test func emittingFromManyThreadsLosesNothing() throws {
    try withBridge { bridge, _ throws in
        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            for number in 0..<100 { bridge.emit("test", "n", ["\(thread)", "\(number)"]) }
        }
        var popped = 0
        while try call(bridge, "app_getevent") != nil { popped += 1 }
        #expect(popped == 800)
    }
}

@Test func appStorageReadsAndWritesTheWholeFile() throws {
    try withBridge { bridge, data throws in
        #expect(try call(bridge, "app_storage") == "")
        #expect(try call(bridge, "app_storage", "{\"a\":1}") == nil)
        #expect(try call(bridge, "app_storage") == "{\"a\":1}")
        #expect(readText(data.appendingPathComponent("storage.json")) == "{\"a\":1}")
    }
}

@Test func theBridgeReadsWritesAndDeletesStorage2Keys() throws {
    try withBridge { bridge, data throws in
        #expect(try call(bridge, "app_storage2", "0") == "")
        #expect(try call(bridge, "app_storage2", "0", "liveset") == nil)
        #expect(try call(bridge, "app_storage2", "0") == "liveset")
        #expect(try call(bridge, "app_storage2", "0", "") == nil)
        #expect(try call(bridge, "app_storage2", "0") == "")
        let left = try FileManager.default.contentsOfDirectory(atPath: data.appendingPathComponent("storage2").path)
        #expect(left == [])
    }
}

@Test func storage2RefusesKeysThatNameAFolder() throws {
    try withBridge { bridge, _ throws in
        for key in ["", ".", ".."] {
            #expect(throws: StorageError.invalidKey(key)) { try call(bridge, "app_storage2", key, "x") }
            #expect(throws: StorageError.invalidKey(key)) { try call(bridge, "app_storage2", key) }
        }
    }
}

@Test func aStorageFileThatCannotBeReadIsAnErrorNotAnEmptyValue() throws {
    try withBridge { bridge, data throws in
        let notUTF8 = Data([0x41, 0xFF, 0xFE])
        try notUTF8.write(to: data.appendingPathComponent("storage.json"))
        try notUTF8.write(to: data.appendingPathComponent("storage2").appendingPathComponent("ID_LIST"))
        #expect(throws: StorageError.self) { try call(bridge, "app_storage") }
        #expect(throws: StorageError.self) { try call(bridge, "app_storage2", "ID_LIST") }
    }
}

@Test func filesInTheAppFoldersAreReadAndWrittenWithTheirFoldersCreated() throws {
    try withBridge { bridge, data throws in
        for folder in [bridge.tempDir.path, data.path] {
            let target = folder + "/made/on/demand/backup.alb"
            #expect(try call(bridge, "fs_writeString", target, "héllo\nworld") == nil)
            #expect(try call(bridge, "fs_readString", target) == "héllo\nworld")
            #expect(try call(bridge, "fs_writeString", target, "") == nil)
            #expect(try call(bridge, "fs_readString", target) == "")
        }
    }
}

@Test func readingSomethingThatIsNotAFileIsAnError() throws {
    try withBridge { bridge, _ throws in
        let missing = bridge.tempDir.path + "/missing.txt"
        #expect(throws: BridgeError(description: "\(escaped(missing)) is not a file")) {
            try call(bridge, "fs_readString", missing)
        }
        let folder = bridge.tempDir.path + "/folder"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        #expect(throws: BridgeError(description: "\(escaped(folder)) is not a file")) {
            try call(bridge, "fs_readString", folder)
        }
    }
}

@Test func theBridgeRefusesPathsOutsideTheAppFolders() throws {
    try withBridge { bridge, data throws in
        let outside = data.deletingLastPathComponent().appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)
        let paths = [
            "/etc/hosts", secret.path, data.path + "/../outside/secret.txt", data.path + "/../outside/new.txt",
        ]
        for path in paths {
            #expect(throws: FileAccessError.self, "\(path)") { try call(bridge, "fs_readString", path) }
            #expect(throws: FileAccessError.self, "\(path)") { try call(bridge, "fs_writeString", path, "x") }
        }
        #expect(readText(secret) == "secret")
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.txt").path))
    }
}

@Test func execOpensWebLinksOnly() throws {
    let opened = OpenedURLs()
    try withBridge(opened: opened) { bridge, _ throws in
        for target in ["/Applications/Calculator.app", "-aCalculator", "file:///etc/hosts", "", "ftp://example.com"] {
            #expect(throws: BridgeError(description: "refusing to open \(escaped(target))")) {
                try call(bridge, "fs_exec", target)
            }
        }
        #expect(opened.all == [])
        #expect(try call(bridge, "fs_exec", "https://www.roland.com/support/") == nil)
        #expect(try call(bridge, "fs_exec", "http://example.com/a?b=c") == nil)
        #expect(try call(bridge, "fs_exec", "HTTPS://www.roland.com/") == nil)  // a scheme has no letter case
        let expected = ["https://www.roland.com/support/", "http://example.com/a?b=c", "HTTPS://www.roland.com/"]
        #expect(opened.all.map(\.absoluteString) == expected)
        #expect(throws: BridgeError(description: "refusing to open '-a\\nCalc'")) {  // escaped, as it reaches logs
            try call(bridge, "fs_exec", "-a\nCalc")
        }
    }
}

@Test func execRefusesLinksBackToThisMac() throws {
    // The page's own URLs carry the token: no spelling a browser reads as this Mac may reach it.
    let opened = OpenedURLs()
    try withBridge(opened: opened) { bridge, _ throws in
        let refused = [
            "http://127.0.0.1:8080/token/index.html", "https://127.0.0.1/", "http://127.0.0.1./", "http://127.1:8080/",
            "http://0x7f000001/", "http://2130706433/", "http://%31%32%37.0.0.1/", "http://0.0.0.0/",
            "http://localhost:8080/", "http://LOCALHOST./", "http://app.localhost/", "http://[::1]:8080/",
            "http://[::]/", "http://[::ffff:127.0.0.1]/", "http:///127.0.0.1/", "http://example.com\\@127.0.0.1/",
            "http://user@example.com/", "HTTP://127.0.0.1:8080/token/", "Https://localhost/",
        ]
        for target in refused {
            #expect(throws: BridgeError(description: "refusing to open \(escaped(target))"), "\(target)") {
                try call(bridge, "fs_exec", target)
            }
        }
        #expect(opened.all == [])
        #expect(try call(bridge, "fs_exec", "https://127.example.com/") == nil)  // a name, not an address
        #expect(try call(bridge, "fs_exec", "http://192.168.1.1/") == nil)
        #expect(try call(bridge, "fs_exec", "http://[2001:db8::1]/") == nil)
        let expected = ["https://127.example.com/", "http://192.168.1.1/", "http://[2001:db8::1]/"]
        #expect(opened.all.map(\.absoluteString) == expected)
    }
}

@Test func openDialogResultIsReadableNotWritable() throws {
    try withTemporaryFolder { outside throws in
        let picked = outside.appendingPathComponent("Foo.tsl")
        try Data("liveset".utf8).write(to: picked)
        let host = FakeHost(openAnswer: picked.path)
        try withBridge(host: host) { bridge, _ throws in
            #expect(try call(bridge, "fs_openfilename", "[\"tsl\"]") == nil)
            #expect(try call(bridge, "app_getevent") == "fs\(formFeed)openfilename\(formFeed)\(picked.path)")
            #expect(try call(bridge, "fs_readString", picked.path) == "liveset")
            #expect(throws: FileAccessError.self) { try call(bridge, "fs_writeString", picked.path, "x") }
            #expect(readText(picked) == "liveset")
            #expect(host.openRequests == [["tsl"]])
        }
    }
}

@Test func theOpenDialogFilterIsOptionalAndMustBeAListOfStrings() throws {
    let host = FakeHost()
    try withBridge(host: host) { bridge, _ throws in
        #expect(try call(bridge, "fs_openfilename") == nil)
        #expect(try call(bridge, "fs_openfilename", "") == nil)
        #expect(try call(bridge, "fs_openfilename", "[\"tsl\", \"alb\"]") == nil)
        #expect(host.openRequests == [[], [], ["tsl", "alb"]])
        for filter in ["tsl", "null", "{\"a\": 1}", "[1]"] {
            #expect(throws: BridgeError(description: "invalid file filter \(escaped(filter))")) {
                try call(bridge, "fs_openfilename", filter)
            }
        }
        #expect(host.openRequests.count == 3)
    }
}

@Test func saveDialogAppendsTheExtension() throws {
    try withTemporaryFolder { outside throws in
        let host = FakeHost(saveAnswer: "/x/name")
        try withBridge(host: host) { bridge, _ throws in
            let cases = [
                ("/x/name", "/x/name.tsl"), ("/x/a.TSL", "/x/a.TSL"), ("/x/b.tsl", "/x/b.tsl"),
                ("/x/tsl", "/x/tsl.tsl"),
                ("/x/c.alb", "/x/c.alb.tsl"),
            ]
            for (answer, event) in cases {
                host.saveAnswer = answer
                #expect(try call(bridge, "fs_savefilename", "Backup", "tsl") == nil)
                #expect(try call(bridge, "app_getevent") == "fs\(formFeed)savefilename\(formFeed)\(event)", "\(answer)")
            }
            // The dialog gets the extension too, so it adds it itself and asks before replacing that file.
            #expect(host.saveRequests == Array(repeating: ["Backup.tsl", "tsl"], count: cases.count))

            // The page writes its backup to the chosen path and may read it back; nothing else opens up.
            host.saveAnswer = outside.appendingPathComponent("name").path
            _ = try call(bridge, "fs_savefilename", "Backup", "tsl")
            let saved = outside.appendingPathComponent("name.tsl").path
            #expect(try call(bridge, "app_getevent") == "fs\(formFeed)savefilename\(formFeed)\(saved)")
            #expect(try call(bridge, "fs_writeString", saved, "backup") == nil)
            #expect(try call(bridge, "fs_readString", saved) == "backup")
            let other = outside.appendingPathComponent("name").path
            #expect(throws: FileAccessError.self) { try call(bridge, "fs_writeString", other, "x") }
        }
    }
}

@Test func cancelledDialogEmitsAnEmptyPath() throws {
    let host = FakeHost()
    try withBridge(host: host) { bridge, _ throws in
        #expect(try call(bridge, "fs_savefilename", "Backup", "tsl") == nil)
        #expect(try call(bridge, "app_getevent") == "fs\(formFeed)savefilename\(formFeed)")
        host.saveAnswer = ""
        #expect(try call(bridge, "fs_savefilename", "Backup", "tsl") == nil)
        #expect(try call(bridge, "app_getevent") == "fs\(formFeed)savefilename\(formFeed)")
        #expect(try call(bridge, "fs_openfilename") == nil)
        #expect(try call(bridge, "app_getevent") == "fs\(formFeed)openfilename\(formFeed)")
        #expect(try call(bridge, "app_getevent") == nil)
    }
}

@Test func theAnswerOfADialogArrivesLaterThanTheCommandReturns() throws {
    let host = FakeHost(holdingDialogs: true)
    try withBridge(host: host) { bridge, _ throws in
        #expect(try call(bridge, "fs_savefilename", "Backup", "tsl") == nil)
        #expect(try call(bridge, "app_getevent") == nil)
        let answered = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            host.answerHeldDialog(with: "/x/later")
            answered.signal()
        }
        answered.wait()
        #expect(try call(bridge, "app_getevent") == "fs\(formFeed)savefilename\(formFeed)/x/later.tsl")
    }
}

@Test func dialogsNeedTheAppWindow() throws {
    try withBridge { bridge, _ throws in
        #expect(try call(bridge, "fs_openfilename") == nil)
        #expect(try call(bridge, "fs_savefilename", "Backup", "tsl") == nil)
        #expect(try call(bridge, "app_getevent") == nil)
    }
}

@Test func saveDialogRefusesAnExtensionThatLeavesTheFolder() throws {
    let host = FakeHost(saveAnswer: "/x/name")
    let refused = [
        "tsl/../../Library/LaunchAgents/x.plist", "", "t.sl", "tsl\n", "tsł", "abcdefghijk", "a b", "../x", "tsl/",
    ]
    try withBridge(host: host) { bridge, _ throws in
        for hasWindow in [true, false] {
            bridge.host = hasWindow ? host : nil
            for ext in refused {
                #expect(throws: BridgeError(description: "refusing extension \(escaped(ext))"), "\(ext)") {
                    try call(bridge, "fs_savefilename", "Backup", ext)
                }
            }
        }
        #expect(host.saveRequests == [])
        #expect(try call(bridge, "app_getevent") == nil)
        bridge.host = host
        for ext in ["a", "TSL", "abcdefghij", "tsl2"] {
            #expect(try call(bridge, "fs_savefilename", "Backup", ext) == nil, "\(ext)")
        }
        let requests = [
            ["Backup.a", "a"], ["Backup.TSL", "TSL"], ["Backup.abcdefghij", "abcdefghij"], ["Backup.tsl2", "tsl2"],
        ]
        #expect(host.saveRequests == requests)
    }
}

@Test func midiCommandsReachTheControllerAndItsEventsTheQueue() throws {
    let midi = FakeMidiBackend()
    let katana = "{\"MIDIEntityNameKey\": \"KATANA\"}"
    try withBridge(midi: midi) { bridge, _ throws in
        #expect(try call(bridge, "midi_inendpoints") == endpointsJSON(["KATANA"]))
        #expect(try call(bridge, "midi_outendpoints") == endpointsJSON(["KATANA"]))
        #expect(try call(bridge, "midi_inconnect", katana) == nil)
        #expect(try call(bridge, "midi_outconnect", katana) == nil)
        #expect(try call(bridge, "midi_send", "F07EF7") == nil)
        #expect(midi.sent == [[0xF0, 0x7E, 0xF7]])

        midi.fireMessage([0x90, 0x40, 0x7F])
        let fields = try #require(try call(bridge, "app_getevent")).components(separatedBy: formFeed)
        #expect(Array(fields.prefix(3)) == ["midi", "message", "90407F"] && fields.count == 4)
        #expect(Int(fields[3]) != nil)

        #expect(try call(bridge, "midi_indisconnect") == nil)
        #expect(try call(bridge, "midi_outdisconnect") == nil)
        #expect(midi.calls.suffix(2) == ["disconnectInput", "disconnectOutput"])
    }
}

@Test func aFailedConnectReachesThePage() throws {
    try withBridge(midi: FakeMidiBackend()) { bridge, _ throws in
        let other = "{\"MIDIEntityNameKey\": \"Other\"}"
        #expect(try call(bridge, "midi_inconnect", other) == nil)
        #expect(try call(bridge, "app_getevent") == "midi\(formFeed)connectfailed\(formFeed)\(other)")
    }
}

// The fallback is `withBridge`'s 60 s, so it cannot fire during the test; `theExitFallbackClosesTheWindow` covers it.
@Test func closingLetsThePageAnswerAndClosesTheWindowOnce() throws {
    let host = FakeHost()
    try withBridge(host: host) { bridge, _ throws in
        #expect(!bridge.windowShouldClose())  // the first close waits for the page
        #expect(try call(bridge, "app_getevent") == "app\(formFeed)command\(formFeed)exit")
        #expect(!bridge.windowShouldClose())  // so does a second click before the page answers
        #expect(try call(bridge, "app_getevent") == nil)  // without asking the page twice
        #expect(host.closeCount == 0)

        #expect(try call(bridge, "app_exit") == nil)  // the page's $$app_exit
        bridge.appExit()  // the fallback, had it fired after all
        #expect(host.closeCount == 1)
        #expect(bridge.host == nil)
        #expect(bridge.windowShouldClose())
        #expect(try call(bridge, "app_getevent") == nil)
    }
}

@Test func theExitFallbackClosesTheWindow() throws {
    let host = FakeHost()
    try withBridge(host: host, exitFallback: .milliseconds(50)) { bridge, _ throws in
        #expect(!bridge.windowShouldClose())
        #expect(host.waitForClose(seconds: 1))
        #expect(host.closeCount == 1)
        #expect(bridge.windowShouldClose())
    }
}

@Test func exitingDisconnectsMIDIAndClosesTheWindow() throws {
    let midi = FakeMidiBackend()
    let host = FakeHost()
    try withBridge(midi: midi, host: host) { bridge, _ throws in
        bridge.appExit()
        #expect(midi.calls == ["disconnectInput", "disconnectOutput"])
        #expect(host.closeCount == 1)
    }
}

@Test func exitingWithoutAWindowIsQuietAndLetsAnyCloseThrough() throws {
    try withBridge { bridge, _ throws in
        #expect(bridge.windowShouldClose())
        bridge.appExit()
        #expect(bridge.windowShouldClose())
    }
}
