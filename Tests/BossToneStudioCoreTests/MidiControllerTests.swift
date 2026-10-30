import Foundation
import Testing

@testable import BossToneStudioCore

private struct PortFailure: Error {}

private struct SendFailure: Error, CustomStringConvertible {
    let description = "MIDISendEventList failed (OSStatus -10)"
}

private struct Event: Equatable {
    let prop: String
    let kind: String
    let args: [String]
}

extension Recorder where T == Event {
    var emit: Emit {
        { prop, kind, args in self.append(Event(prop: prop, kind: kind, args: args)) }
    }
}

private func controller(
    _ backend: FakeMidiBackend?, _ events: Recorder<Event>, log: Recorder<String> = Recorder()
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
            let events = Recorder<Event>()
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
    let midi = controller(backend, Recorder<Event>())
    midi.connectInput(endpointsJSON(["KATANA"]).trimmingBrackets)
    midi.connectInput("{\"MIDIEntityNameKey\": \"Other\"}")
    #expect(backend.calls == ["disconnectInput", "connectInput KATANA", "disconnectInput"])
}

@Test func aSuccessfulConnectEmitsNothing() {
    let backend = FakeMidiBackend()
    let events = Recorder<Event>()
    let midi = controller(backend, events)
    midi.connectInput(endpointsJSON(["KATANA"]).trimmingBrackets)
    midi.connectOutput(endpointsJSON(["KATANA"]).trimmingBrackets)
    #expect(events.all.isEmpty)
    #expect(backend.calls.contains("connectInput KATANA"))
    #expect(backend.calls.contains("connectOutput KATANA"))
}

@Test func aPortWithMarkupInItsNameCannotBeOpenedEither() {
    let backend = FakeMidiBackend(sources: ["<b>x"], destinations: ["<b>x"])
    let events = Recorder<Event>()
    let midi = controller(backend, events)
    midi.connectInput(endpointsJSON(["<b>x"]).trimmingBrackets)
    #expect(events.all.count == 1)
    #expect(backend.calls == ["disconnectInput"])
}

@Test func sendSplitsIntoWholeMessages() throws {
    let backend = FakeMidiBackend()
    let midi = controller(backend, Recorder<Event>())
    midi.connectOutput(endpointsJSON(["KATANA"]).trimmingBrackets)
    try midi.send("B00764F07E7FF7")
    #expect(backend.sent == [[0xB0, 0x07, 0x64], [0xF0, 0x7E, 0x7F, 0xF7]])
}

@Test func sendWithoutAnOutputDoesNothing() throws {
    let backend = FakeMidiBackend()
    let midi = controller(backend, Recorder<Event>())
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
    let log = Recorder<String>()
    let midi = controller(backend, Recorder<Event>(), log: log)
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
    let midi = controller(backend, Recorder<Event>())
    midi.connectOutput(endpointsJSON(["KATANA"]).trimmingBrackets)
    #expect(throws: HexError.notHexadecimal) { try midi.send("zz") }
    #expect(throws: HexError.oddLength) { try midi.send("B0076") }
    #expect(backend.sent.isEmpty)
}

@Test func incomingMessagesAreEmittedAsUppercaseHex() throws {
    let backend = FakeMidiBackend()
    let events = Recorder<Event>()
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
    let events = Recorder<Event>()
    let midi = controller(backend, events)
    midi.connectInput(endpointsJSON(["KATANA"]).trimmingBrackets)
    midi.disconnectInput()
    backend.fireMessage([0xC0, 0x05])
    #expect(events.all.isEmpty)
}

@Test func changedIsEmittedOnlyWhenPortsReallyChange() {
    let backend = FakeMidiBackend()
    let events = Recorder<Event>()
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
    let events = Recorder<Event>()
    var midi: MidiController? = controller(backend, events)
    backend.setPorts(sources: [], destinations: [])
    midi = nil
    backend.fireSetupChanged()
    #expect(events.all.isEmpty)
    #expect(midi == nil)
}

@Test func aSetupChangeReportedFromInsideABackendCallDoesNotDeadlock() throws {
    let backend = FakeMidiBackend()
    let events = Recorder<Event>()
    let midi = controller(backend, events)
    backend.reportSetupChangeDuringCalls()
    midi.connectOutput(endpointsJSON(["KATANA"]).trimmingBrackets)
    try midi.send("F07EF7")
    midi.connectInput(endpointsJSON(["KATANA"]).trimmingBrackets)
    #expect(backend.sent == [[0xF0, 0x7E, 0xF7]])
    #expect(!events.all.contains { $0.kind == "connectfailed" })
}

@Test func messagesOfOneSendAreNotInterleavedWithAnotherSend() throws {
    let backend = FakeMidiBackend()
    let midi = controller(backend, Recorder<Event>())
    midi.connectOutput(endpointsJSON(["KATANA"]).trimmingBrackets)
    DispatchQueue.concurrentPerform(iterations: 8) { i in try? midi.send("903C0\(i)803C0\(i)") }

    let sent = backend.sent
    try #require(sent.count == 16)
    for pair in stride(from: 0, to: sent.count, by: 2) {
        #expect(sent[pair].first == 0x90)
        #expect(sent[pair + 1] == [0x80, 0x3C, sent[pair][2]])
    }
    #expect(Set(sent.map { $0[2] }) == Set(0..<8))
}

@Test func withoutCoreMIDIListsAreEmptyAndConnectsFail() throws {
    let events = Recorder<Event>()
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
    let midi = controller(backend, Recorder<Event>())
    #expect(midi.inputs() == endpointsJSON(["KATANA", "KATANA DAW CTRL"]))
    #expect(midi.outputs() == endpointsJSON(["KATANA"]))
}

@Test func markupPortNamesAreHidden() {
    let backend = FakeMidiBackend(sources: ["<b>x", "KATANA"], destinations: ["a&b", "KATANA"])
    let midi = controller(backend, Recorder<Event>())
    #expect(midi.inputs() == endpointsJSON(["KATANA"]))
    #expect(midi.outputs() == endpointsJSON(["KATANA"]))
}

@Test func disconnectAllClosesBothPorts() {
    let backend = FakeMidiBackend()
    let midi = controller(backend, Recorder<Event>())
    midi.disconnectAll()
    #expect(backend.calls == ["disconnectInput", "disconnectOutput"])
}

extension String {
    /// `endpointsJSON` makes an array; the page hands one endpoint object back.
    fileprivate var trimmingBrackets: String { String(dropFirst().dropLast()) }
}
