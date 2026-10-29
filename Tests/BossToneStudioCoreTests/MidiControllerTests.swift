import Foundation
import Testing
import os

@testable import BossToneStudioCore

private struct PortFailure: Error {}

private struct SendFailure: Error, CustomStringConvertible {
    let description = "MIDISendEventList failed (OSStatus -10)"
}

/// Records what the controller does and lets a test play the part of CoreMIDI.
private final class FakeMidiBackend: MidiBackend {
    private struct State {
        var sources: [String]
        var destinations: [String]
        var calls: [String] = []
        var sent: [[UInt8]] = []
        var openError: (any Error)?
        var sendError: (any Error)?
        var onMessage: (@Sendable ([UInt8]) -> Void)?
        var onSetupChanged: (@Sendable () -> Void)?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(sources: [String] = ["KATANA"], destinations: [String] = ["KATANA"]) {
        state = OSAllocatedUnfairLock(initialState: State(sources: sources, destinations: destinations))
    }

    var calls: [String] { state.withLock { $0.calls } }
    var sent: [[UInt8]] { state.withLock { $0.sent } }

    func setPorts(sources: [String], destinations: [String]) {
        state.withLock {
            $0.sources = sources
            $0.destinations = destinations
        }
    }

    func failOpening(with error: any Error) {
        state.withLock { $0.openError = error }
    }

    func failSending(with error: any Error) {
        state.withLock { $0.sendError = error }
    }

    /// What CoreMIDI does when the notification thread reports a changed setup.
    func fireSetupChanged() {
        state.withLock { $0.onSetupChanged }?()
    }

    func fireMessage(_ message: [UInt8]) {
        state.withLock { $0.onMessage }?(message)
    }

    func sourceNames() -> [String] { state.withLock { $0.sources } }
    func destinationNames() -> [String] { state.withLock { $0.destinations } }

    func connectInput(named name: String, onMessage: @escaping @Sendable ([UInt8]) -> Void) throws {
        try state.withLock {
            $0.calls.append("connectInput \(name)")
            if let error = $0.openError { throw error }
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
        try state.withLock {
            $0.calls.append("connectOutput \(name)")
            if let error = $0.openError { throw error }
        }
    }

    func disconnectOutput() {
        state.withLock { $0.calls.append("disconnectOutput") }
    }

    func send(_ message: [UInt8]) throws {
        try state.withLock {
            $0.calls.append("send")
            if let error = $0.sendError { throw error }
            $0.sent.append(message)
        }
    }

    func onSetupChanged(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.onSetupChanged = handler }
    }
}

private struct Event: Equatable {
    let prop: String
    let kind: String
    let args: [String]
}

private final class Events: Sendable {
    private let recorded = OSAllocatedUnfairLock(initialState: [Event]())

    var all: [Event] { recorded.withLock { $0 } }

    var emit: Emit {
        { prop, kind, args in self.recorded.withLock { $0.append(Event(prop: prop, kind: kind, args: args)) } }
    }

    func clear() { recorded.withLock { $0.removeAll() } }
}

/// What the controller printed, line by line.
private final class LogLines: Sendable {
    private let lines = OSAllocatedUnfairLock(initialState: [String]())

    var all: [String] { lines.withLock { $0 } }

    func append(_ line: String) { lines.withLock { $0.append(line) } }
}

private func controller(
    _ backend: FakeMidiBackend?, _ events: Events, log: LogLines = LogLines()
) -> MidiController {
    MidiController(backend: backend, emit: events.emit, output: log.append)
}

@Test func aMissingOrUnopenablePortReportsConnectfailed() {
    let katanaJSON = "{\"MIDIEntityNameKey\": \"KATANA\"}"
    let unlisted = "{\"MIDIEntityNameKey\": \"Other\"}"
    let cases: [(label: String, json: String?, error: (any Error)?, expected: String)] = [
        ("unknown name", unlisted, nil, unlisted),
        ("backend refuses", katanaJSON, PortFailure(), katanaJSON),
        ("no endpoint at all", nil, nil, ""),
        ("no name in the endpoint", "{}", nil, "{}"),
        ("not JSON", "KATANA", nil, "KATANA"),
    ]
    for testCase in cases {
        for connect in [MidiController.connectInput, MidiController.connectOutput] {
            let backend = FakeMidiBackend()
            let events = Events()
            if let error = testCase.error { backend.failOpening(with: error) }
            connect(controller(backend, events))(testCase.json)
            #expect(
                events.all == [Event(prop: "midi", kind: "connectfailed", args: [testCase.expected])],
                "\(testCase.label)")
        }
    }
}

@Test func connectingDisconnectsTheOldPortFirstEvenWhenTheNewOneFails() {
    let backend = FakeMidiBackend()
    let midi = controller(backend, Events())
    midi.connectInput(endpointsJSON(["KATANA"]).trimmingBrackets)
    midi.connectInput("{\"MIDIEntityNameKey\": \"Other\"}")
    #expect(backend.calls == ["disconnectInput", "connectInput KATANA", "disconnectInput"])
}

@Test func aSuccessfulConnectEmitsNothing() {
    let backend = FakeMidiBackend()
    let events = Events()
    let midi = controller(backend, events)
    midi.connectInput(endpointsJSON(["KATANA"]).trimmingBrackets)
    midi.connectOutput(endpointsJSON(["KATANA"]).trimmingBrackets)
    #expect(events.all.isEmpty)
    #expect(backend.calls.contains("connectInput KATANA"))
    #expect(backend.calls.contains("connectOutput KATANA"))
}

@Test func aPortWithMarkupInItsNameCannotBeOpenedEither() {
    let backend = FakeMidiBackend(sources: ["<b>x"], destinations: ["<b>x"])
    let events = Events()
    let midi = controller(backend, events)
    midi.connectInput(endpointsJSON(["<b>x"]).trimmingBrackets)
    #expect(events.all.count == 1)
    #expect(backend.calls == ["disconnectInput"])
}

@Test func sendSplitsIntoWholeMessages() throws {
    let backend = FakeMidiBackend()
    let midi = controller(backend, Events())
    midi.connectOutput(endpointsJSON(["KATANA"]).trimmingBrackets)
    try midi.send("B00764F07E7FF7")
    #expect(backend.sent == [[0xB0, 0x07, 0x64], [0xF0, 0x7E, 0x7F, 0xF7]])
}

@Test func sendWithoutAnOutputDoesNothing() throws {
    let backend = FakeMidiBackend()
    let midi = controller(backend, Events())
    try midi.send("B00764")
    #expect(backend.sent.isEmpty)
    // The hex is not even looked at, as in 0.1.1, where the output check came first.
    try midi.send("not hex")
    midi.connectOutput(endpointsJSON(["KATANA"]).trimmingBrackets)
    midi.disconnectOutput()
    try midi.send("B00764")
    #expect(backend.sent.isEmpty)
}

@Test func aFailedSendIsLoggedAndTheNextMessageStillGoesOut() throws {
    // python-rtmidi reported CoreMIDI's send errors as warnings: the page never saw one.
    let backend = FakeMidiBackend()
    let log = LogLines()
    let midi = controller(backend, Events(), log: log)
    midi.connectOutput(endpointsJSON(["KATANA"]).trimmingBrackets)
    backend.failSending(with: SendFailure())
    try midi.send("B00764F07E7FF7")
    #expect(backend.calls.filter { $0 == "send" }.count == 2)
    let line = "[bts] sending MIDI failed: 'MIDISendEventList failed (OSStatus -10)'"
    #expect(log.all == [line, line])
    #expect(throws: HexError.notHexadecimal) { try midi.send("zz") }  // the page's own mistake still is one
}

@Test func sendRejectsTextThatIsNotHexOnceAnOutputIsOpen() {
    let backend = FakeMidiBackend()
    let midi = controller(backend, Events())
    midi.connectOutput(endpointsJSON(["KATANA"]).trimmingBrackets)
    #expect(throws: HexError.notHexadecimal) { try midi.send("zz") }
    #expect(throws: HexError.oddLength) { try midi.send("B0076") }
    #expect(backend.sent.isEmpty)
}

@Test func incomingMessagesAreEmittedAsUppercaseHex() throws {
    let backend = FakeMidiBackend()
    let events = Events()
    let midi = controller(backend, events)
    midi.connectInput(endpointsJSON(["KATANA"]).trimmingBrackets)
    let before = Int(Date().timeIntervalSince1970 * 1000)
    backend.fireMessage([0xF0, 0x41, 0xF7])
    let after = Int(Date().timeIntervalSince1970 * 1000)

    let event = try #require(events.all.first)
    #expect(events.all.count == 1)
    #expect(event.prop == "midi")
    #expect(event.kind == "message")
    #expect(event.args.count == 2)
    #expect(event.args[0] == "F041F7")
    let timestamp = try #require(Int(event.args[1]))  // milliseconds since the epoch, as text
    #expect((before...after).contains(timestamp))
}

@Test func noMessagesAreEmittedAfterDisconnectingTheInput() {
    let backend = FakeMidiBackend()
    let events = Events()
    let midi = controller(backend, events)
    midi.connectInput(endpointsJSON(["KATANA"]).trimmingBrackets)
    midi.disconnectInput()
    backend.fireMessage([0xC0, 0x05])
    #expect(events.all.isEmpty)
}

@Test func changedIsEmittedOnlyWhenPortsReallyChange() {
    let backend = FakeMidiBackend()
    let events = Events()
    let midi = controller(backend, events)
    withExtendedLifetime(midi) {  // the backend holds the controller weakly
        backend.fireSetupChanged()  // CoreMIDI also notifies about things that leave the lists alone
        #expect(events.all.isEmpty)

        backend.setPorts(sources: ["KATANA", "KATANA DAW CTRL"], destinations: ["KATANA"])
        backend.fireSetupChanged()
        #expect(events.all == [Event(prop: "midi", kind: "changed", args: [])])

        backend.fireSetupChanged()  // the same lists again
        #expect(events.all.count == 1)

        backend.setPorts(sources: ["KATANA", "KATANA DAW CTRL"], destinations: [])
        backend.fireSetupChanged()  // only a destination went away
        #expect(events.all.count == 2)
    }
}

@Test func aSetupChangeAfterTheControllerIsGoneIsIgnored() {
    let backend = FakeMidiBackend()
    let events = Events()
    var midi: MidiController? = controller(backend, events)
    backend.setPorts(sources: [], destinations: [])
    midi = nil
    backend.fireSetupChanged()
    #expect(events.all.isEmpty)
    #expect(midi == nil)
}

@Test func withoutCoreMIDIListsAreEmptyAndConnectsFail() throws {
    let events = Events()
    let midi = controller(nil, events)
    #expect(midi.inputs() == "[]")
    #expect(midi.outputs() == "[]")

    let json = endpointsJSON(["KATANA"]).trimmingBrackets
    midi.connectInput(json)
    midi.connectOutput(json)
    #expect(events.all.map(\.kind) == ["connectfailed", "connectfailed"])
    #expect(events.all.map(\.args) == [[json], [json]])

    midi.disconnectAll()
    try midi.send("B00764")  // nothing to send to, nothing to complain about
}

@Test func inputsAndOutputsListTheEndpointsOfTheBackend() {
    let backend = FakeMidiBackend(sources: ["KATANA", "KATANA DAW CTRL"], destinations: ["KATANA"])
    let midi = controller(backend, Events())
    #expect(midi.inputs() == endpointsJSON(["KATANA", "KATANA DAW CTRL"]))
    #expect(midi.outputs() == endpointsJSON(["KATANA"]))
}

@Test func markupPortNamesAreHidden() {
    let backend = FakeMidiBackend(sources: ["<b>x", "KATANA"], destinations: ["a&b", "KATANA"])
    let midi = controller(backend, Events())
    #expect(midi.inputs() == endpointsJSON(["KATANA"]))
    #expect(midi.outputs() == endpointsJSON(["KATANA"]))
}

@Test func disconnectAllClosesBothPorts() {
    let backend = FakeMidiBackend()
    let midi = controller(backend, Events())
    midi.disconnectAll()
    #expect(backend.calls == ["disconnectInput", "disconnectOutput"])
}

extension String {
    /// `endpointsJSON` makes an array; the page hands one endpoint object back.
    fileprivate var trimmingBrackets: String { String(dropFirst().dropLast()) }
}
