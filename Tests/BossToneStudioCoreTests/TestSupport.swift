import Darwin
import Foundation
import os

@testable import BossToneStudioCore

/// One fresh folder per test, removed afterwards, so tests never see each other's files.
func withTemporaryFolder<T>(_ body: (URL) throws -> T) throws -> T {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bts-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    return try body(folder)
}

/// What the file system says a path is: `realpath` directly, so tests do not lean on the code they check.
func onDisk(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// What a stand-in was handed, in order, from any thread.
final class Recorder<T: Sendable>: Sendable {
    private let items = OSAllocatedUnfairLock(initialState: [T]())

    var all: [T] { items.withLock { $0 } }

    func append(_ item: T) { items.withLock { $0.append(item) } }

    func clear() { items.withLock { $0.removeAll() } }
}

/// Records what the controller does and lets a test play the part of CoreMIDI.
final class FakeMidiBackend: MidiBackend {
    private struct State {
        var sources: [String]
        var destinations: [String]
        var calls: [String] = []
        var sent: [[UInt8]] = []
        var openError: (any Error)?
        var sendError: (any Error)?
        var onMessage: (@Sendable ([UInt8]) -> Void)?
        var onSetupChanged: (@Sendable () -> Void)?
        var reportsSetupChangeDuringCalls = false
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

    /// From now on `connectInput`, `connectOutput` and `send` report a setup change before they return, which nothing
    /// in CoreMIDI's contract rules out.
    func reportSetupChangeDuringCalls() {
        state.withLock { $0.reportsSetupChangeDuringCalls = true }
    }

    private func reportSetupChangeIfAsked() {
        state.withLock { $0.reportsSetupChangeDuringCalls ? $0.onSetupChanged : nil }?()
    }

    func sourceNames() -> [String] { state.withLock { $0.sources } }
    func destinationNames() -> [String] { state.withLock { $0.destinations } }

    func connectInput(named name: String, onMessage: @escaping @Sendable ([UInt8]) -> Void) throws {
        try state.withLock {
            $0.calls.append("connectInput \(name)")
            if let error = $0.openError { throw error }
            $0.onMessage = onMessage
        }
        reportSetupChangeIfAsked()
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
        reportSetupChangeIfAsked()
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
        reportSetupChangeIfAsked()
    }

    func onSetupChanged(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.onSetupChanged = handler }
    }
}
