import BossToneStudioCore
import CoreMIDI
import Foundation
import os

struct CoreMIDIError: Error, CustomStringConvertible {
    let description: String
}

/// `MidiBackend` on CoreMIDI, with ports named as python-rtmidi named them in 0.1.1: the page stored that name as the
/// device's UID (ADR-0005), so a different one would send users back to the device picker. Names are taken as CoreMIDI
/// holds them, though: python-rtmidi decoded them as MacRoman (`encoding='auto'`), so a device whose name has
/// non-ASCII characters goes through the picker once.
///
/// CoreMIDI calls the notification block and each input's receive block on threads of its own, never from inside the
/// calls below, and no lock is held across a CoreMIDI call: the contract on `MidiBackend` holds.
final class CoreMIDIBackend: MidiBackend {
    private struct Input {
        let port: MIDIPortRef
        let session: InputSession
    }

    private struct State {
        var input: Input?
        var destination: MIDIEndpointRef?
        var setupChanged: (@Sendable () -> Void)?
    }

    /// `MIDIEventListAdd` takes lists of at most 64 KB; longer messages go out in several.
    private static let maxListBytes = 65_536
    private static let listHeaderBytes = MemoryLayout<MIDIEventList>.offset(of: \MIDIEventList.packet) ?? 8
    private static let packetHeaderBytes = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words) ?? 12

    private let client: MIDIClientRef
    private let outputPort: MIDIPortRef
    private let state: OSAllocatedUnfairLock<State>

    /// Fails where no MIDI client can be made (Claude Code's sandbox, for one).
    init() throws {
        let state = OSAllocatedUnfairLock(initialState: State())
        var client = MIDIClientRef()
        let created = MIDIClientCreateWithBlock(AppPaths.appName as CFString, &client) { notification in
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            state.withLock { $0.setupChanged }?()
        }
        try check(created, "MIDIClientCreateWithBlock")
        var outputPort = MIDIPortRef()
        try check(MIDIOutputPortCreate(client, "output" as CFString, &outputPort), "MIDIOutputPortCreate")
        (self.client, self.outputPort, self.state) = (client, outputPort, state)
    }

    func sourceNames() -> [String] {
        (0..<MIDIGetNumberOfSources()).map { Self.endpointName(MIDIGetSource($0)) }
    }

    func destinationNames() -> [String] {
        (0..<MIDIGetNumberOfDestinations()).map { Self.endpointName(MIDIGetDestination($0)) }
    }

    func connectInput(named name: String, onMessage: @escaping @Sendable ([UInt8]) -> Void) throws {
        disconnectInput()
        let sources = (0..<MIDIGetNumberOfSources()).map(MIDIGetSource)
        guard let source = sources.first(where: { Self.endpointName($0) == name }) else {
            throw CoreMIDIError(description: "no MIDI source is named \(name)")
        }
        // A new port and reassembler for every connection: a SysEx cut off by the last one must not run into this one.
        let session = InputSession(onMessage: onMessage)
        var created = MIDIPortRef()
        let status = MIDIInputPortCreateWithProtocol(client, "input" as CFString, ._1_0, &created) { list, _ in
            session.receive(list)
        }
        try check(status, "MIDIInputPortCreateWithProtocol")
        let input = Input(port: created, session: session)
        do {
            try check(MIDIPortConnectSource(input.port, source, nil), "MIDIPortConnectSource")
        } catch {
            close(input)
            throw error
        }
        // Empty since the disconnect above: the controller makes these calls one at a time, under its lock.
        state.withLock { $0.input = input }
    }

    func disconnectInput() {
        let input = state.withLock { state in
            defer { state.input = nil }
            return state.input
        }
        if let input { close(input) }
    }

    func connectOutput(named name: String) throws {
        let destinations = (0..<MIDIGetNumberOfDestinations()).map(MIDIGetDestination)
        guard let destination = destinations.first(where: { Self.endpointName($0) == name }) else {
            throw CoreMIDIError(description: "no MIDI destination is named \(name)")
        }
        state.withLock { $0.destination = destination }
    }

    func disconnectOutput() {
        state.withLock { $0.destination = nil }
    }

    func send(_ message: [UInt8]) throws {
        guard let destination = state.withLock({ $0.destination }) else { return }
        var batch: [[UInt32]] = []
        var bytes = Self.listHeaderBytes
        for packet in Self.packets(umpWords(for: message)) {
            // Sized for the worst case, one event packet per UMP, so adding to the list cannot run out of room.
            let cost = Self.packetHeaderBytes + 4 * packet.count
            if bytes + cost > Self.maxListBytes {
                try send(batch, bytes: bytes, to: destination)
                (batch, bytes) = ([], Self.listHeaderBytes)
            }
            batch.append(packet)
            bytes += cost
        }
        if !batch.isEmpty { try send(batch, bytes: bytes, to: destination) }
    }

    func onSetupChanged(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.setupChanged = handler }
    }

    /// rtmidi's `CreateEndpointName(endpoint, false)`, which python-rtmidi 1.5 reported for every port without
    /// connections drawn in Audio MIDI Setup (ADR-0011): the endpoint's name without surrounding spaces, else its
    /// entity's; then the device's name in front, unless the result already starts with it (`KATANA` stays `KATANA`,
    /// `DAW CTRL` becomes `KATANA DAW CTRL`).
    static func endpointName(_ endpoint: MIDIEndpointRef) -> String {
        var name = stringProperty(endpoint).trimmingCharacters(in: CharacterSet(charactersIn: " "))
        var entity = MIDIEntityRef()
        MIDIEndpointGetEntity(endpoint, &entity)
        guard entity != 0 else { return name }  // a virtual endpoint
        if name.isEmpty { name = stringProperty(entity) }
        var device = MIDIDeviceRef()
        MIDIEntityGetDevice(entity, &device)
        guard device != 0 else { return name }
        let deviceName = stringProperty(device)
        if name.isEmpty { return deviceName }
        // CoreFoundation compares the UTF-16 units literally.
        guard !deviceName.isEmpty, !name.utf16.starts(with: deviceName.utf16) else { return name }
        return deviceName + " " + name
    }

    private static func stringProperty(_ object: MIDIObjectRef) -> String {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, kMIDIPropertyName, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }

    /// The UMPs in `umpWords`' output: SysEx7 takes two words, everything else one.
    private static func packets(_ words: [UInt32]) -> [[UInt32]] {
        var packets: [[UInt32]] = []
        var index = 0
        while index < words.count {
            let size = words[index] >> 28 == 0x3 ? 2 : 1
            packets.append(Array(words[index..<min(index + size, words.count)]))
            index += size
        }
        return packets
    }

    private func send(_ packets: [[UInt32]], bytes: Int, to destination: MIDIEndpointRef) throws {
        // Never smaller than the struct itself, whose declared single packet the pointer is bound to.
        let size = max(bytes, MemoryLayout<MIDIEventList>.size)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<MIDIEventList>.alignment)
        defer { buffer.deallocate() }
        let list = buffer.bindMemory(to: MIDIEventList.self, capacity: 1)
        var builder = UnsafeMutableMIDIEventListPointer(list, wordSize: size / 4, inProtocol: ._1_0)
        for packet in packets {
            guard builder.append(timestamp: 0, words: packet) != nil else {  // 0: now
                throw CoreMIDIError(description: "a MIDI message did not fit its event list")
            }
        }
        try check(MIDISendEventList(outputPort, destination, list), "MIDISendEventList")
    }

    /// The session first, so no message is passed on once this returns; then the port.
    private func close(_ input: Input) {
        input.session.close()
        MIDIPortDispose(input.port)
    }
}

/// One open input: its reassembler, and whether messages may still be passed on.
private final class InputSession: Sendable {
    private struct State {
        var reassembler = UMPReassembler()
        var open = true
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onMessage: @Sendable ([UInt8]) -> Void

    init(onMessage: @escaping @Sendable ([UInt8]) -> Void) {
        self.onMessage = onMessage
    }

    /// On CoreMIDI's receive thread. `onMessage` only queues an event, so it runs under this session's lock, which
    /// nothing else but `close` takes.
    func receive(_ list: UnsafePointer<MIDIEventList>) {
        let words = list.unsafeSequence().flatMap { $0.words() }
        state.withLock { state in
            guard state.open else { return }
            for message in state.reassembler.feed(words) { onMessage(message) }
        }
    }

    func close() {
        state.withLock { $0.open = false }
    }
}

private func check(_ status: OSStatus, _ call: String) throws {
    guard status == noErr else { throw CoreMIDIError(description: "\(call) failed (OSStatus \(status))") }
}
