import Foundation
import os

/// What the controller needs from CoreMIDI; the real implementation lives in the app, so everything here is testable
/// without a MIDI client. Implementations must be safe to call from any thread.
///
/// The controller holds its own lock while it calls `connectInput`, `disconnectInput`, `connectOutput`,
/// `disconnectOutput` and `send`. So an implementation must never call the setup-changed handler or an `onMessage`
/// callback synchronously from inside those calls, nor while it holds a lock that `sourceNames()` or
/// `destinationNames()` need: the handler lists the ports and then takes the controller's lock.
public protocol MidiBackend: AnyObject, Sendable {
    func sourceNames() -> [String]
    func destinationNames() -> [String]
    /// `onMessage` gets each whole incoming message, from the backend's own thread. Disconnecting without a
    /// connection is not an error; once `disconnectInput` has returned, `onMessage` is not called again.
    func connectInput(named name: String, onMessage: @escaping @Sendable ([UInt8]) -> Void) throws
    func disconnectInput()
    func connectOutput(named name: String) throws
    func disconnectOutput()
    /// One whole MIDI 1.0 message.
    func send(_ message: [UInt8]) throws
    /// The handler may run on any thread, and also for changes that leave the port lists alone.
    func onSetupChanged(_ handler: @escaping @Sendable () -> Void)
}

/// Called from CoreMIDI's threads, possibly while the controller holds its own lock. An implementation must return
/// promptly: take only a short lock of its own (as `Bridge.emit` does, to append to its event queue), never block on
/// anything else, and never call back into the controller.
public typealias Emit = @Sendable (_ prop: String, _ kind: String, _ args: [String]) -> Void

/// The MIDI side of Roland's `$native.midi`, as 0.1.1's Python version did it: port lists in the page's endpoint
/// shape, one open input and output chosen by name, and `midi` events for incoming messages, failed connects and port
/// changes.
public final class MidiController: Sendable {
    private struct Ports: Equatable, Sendable {
        let sources: [String]
        let destinations: [String]
    }

    private struct State {
        var ports: Ports
        var outputOpen = false
    }

    private let backend: MidiBackend?
    private let emit: Emit
    // Held across backend calls, as the Python lock was: a send is never interleaved with another send or with a
    // disconnect. Events are emitted after it is released.
    private let state: OSAllocatedUnfairLock<State>

    /// A nil backend stands for a Mac without CoreMIDI: nothing is listed and every connect fails.
    public init(backend: MidiBackend?, emit: @escaping Emit) {
        self.backend = backend
        self.emit = emit
        state = OSAllocatedUnfairLock(initialState: State(ports: Self.ports(of: backend)))
        backend?.onSetupChanged { [weak self] in self?.setupChanged() }
    }

    public func inputs() -> String {
        endpointsJSON(listable(backend?.sourceNames() ?? []))
    }

    public func outputs() -> String {
        endpointsJSON(listable(backend?.destinationNames() ?? []))
    }

    public func connectInput(_ endpointJSON: String?) {
        let name = endpointJSON.flatMap(entityName(fromEndpointJSON:))
        let failure = state.withLock { _ in
            backend?.disconnectInput()
            return openPort(name, among: backend?.sourceNames() ?? []) { backend, name in
                try backend.connectInput(named: name) { [emit] message in
                    emit("midi", "message", [hex(message), String(Int(Date().timeIntervalSince1970 * 1000))])
                }
            }
        }
        report(failure, of: name, endpointJSON)
    }

    public func connectOutput(_ endpointJSON: String?) {
        let name = endpointJSON.flatMap(entityName(fromEndpointJSON:))
        let failure = state.withLock { state in
            state.outputOpen = false
            backend?.disconnectOutput()
            let failure = openPort(name, among: backend?.destinationNames() ?? []) { backend, name in
                try backend.connectOutput(named: name)
            }
            state.outputOpen = failure == nil
            return failure
        }
        report(failure, of: name, endpointJSON)
    }

    public func disconnectInput() {
        state.withLock { _ in backend?.disconnectInput() }
    }

    public func disconnectOutput() {
        state.withLock { state in
            state.outputOpen = false
            backend?.disconnectOutput()
        }
    }

    public func disconnectAll() {
        disconnectInput()
        disconnectOutput()
    }

    /// Without an open output this does nothing, and the hex is not checked either.
    public func send(_ hex: String) throws {
        try state.withLock { state in
            guard state.outputOpen, let backend else { return }
            for message in splitMessages(try bytes(fromHex: hex)) {
                try backend.send(message)
            }
        }
    }

    private static func ports(of backend: MidiBackend?) -> Ports {
        Ports(sources: backend?.sourceNames() ?? [], destinations: backend?.destinationNames() ?? [])
    }

    /// The page puts names into its HTML (see `isListablePortName`), so a hidden port cannot be opened either.
    private func listable(_ names: [String]) -> [String] {
        names.filter(isListablePortName)
    }

    /// nil when the port is open, else the reason it is not. The name must still be listed: a device that was
    /// unplugged since the page's last list is a failed connect, not a crash.
    private func openPort(
        _ name: String?, among names: [String], connecting connect: (MidiBackend, String) throws -> Void
    ) -> String? {
        guard let backend else { return "CoreMIDI is not available" }
        guard let name else { return "no port name" }
        guard listable(names).contains(name) else { return "port not listed" }
        do {
            try connect(backend, name)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    private func report(_ failure: String?, of name: String?, _ endpointJSON: String?) {
        guard let failure else { return }
        log("opening MIDI port \(name.map(escaped) ?? "None") failed: \(escaped(failure))")
        emit("midi", "connectfailed", [endpointJSON ?? ""])
    }

    private func setupChanged() {
        let current = Self.ports(of: backend)
        let changed = state.withLock { state in
            guard state.ports != current else { return false }
            state.ports = current
            return true
        }
        if changed { emit("midi", "changed", []) }
    }
}
