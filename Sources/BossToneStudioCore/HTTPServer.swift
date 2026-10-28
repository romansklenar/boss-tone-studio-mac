import Foundation
import Network
import os

/// HTTP/1.1 on `127.0.0.1` only, at a port the system picks. Each connection answers its requests one at a time and in
/// order; connections run concurrently, so a slow request (a proxy fetch, a pending command) holds up only its own.
/// Keep-alive matters: the page polls `$$app_getevent` every 50 ms with synchronous XHR.
public final class HTTPServer: Sendable {
    private struct State {
        var listener: NWListener?
        var connections: [ObjectIdentifier: NWConnection] = [:]
        var stopped = false
    }

    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private let idleTimeout: DispatchTimeInterval
    private let output: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "bts.http")
    private let state = OSAllocatedUnfairLock(initialState: State())

    public convenience init(handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.init(handler: handler, idleTimeout: .seconds(30)) { print($0) }
    }

    /// A connection is closed after `idleTimeout` without a complete request, so a stalled request (or a head with
    /// bare line feeds, which never completes) cannot hold it forever. `output` prints one log line.
    init(
        handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse, idleTimeout: DispatchTimeInterval,
        output: @escaping @Sendable (String) -> Void
    ) {
        self.handler = handler
        self.idleTimeout = idleTimeout
        self.output = output
    }

    /// Binds `127.0.0.1:0`, waits until the listener is ready and returns its port.
    public func start() throws -> UInt16 {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true  // answers are one write each; the page's polls should not wait for Nagle
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters)
        let started = state.withLock { state in
            guard state.listener == nil, !state.stopped else { return false }
            state.listener = listener
            return true
        }
        guard started else { throw ServerError(description: "the server was already started") }

        let settled = DispatchSemaphore(value: 0)
        // The handler records the outcome only: capturing the listener would make a cycle that outlives `stop()`.
        let outcome = OSAllocatedUnfairLock<Result<Void, NWError>?>(initialState: nil)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                outcome.withLock { $0 = $0 ?? .success(()) }
                settled.signal()
            case .failed(let error):
                outcome.withLock { $0 = $0 ?? .failure(error) }
                settled.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            accept(connection)
        }
        listener.start(queue: queue)
        _ = settled.wait(timeout: .now() + 10)
        let result = outcome.withLock { $0 }
        if case .success = result, let port = listener.port?.rawValue, port != 0 { return port }
        stop()
        if case .failure(let error) = result { throw ServerError(description: "cannot listen on 127.0.0.1: \(error)") }
        throw ServerError(description: "cannot listen on 127.0.0.1: no port within 10 s")
    }

    /// Connections whose receive loop has not ended yet.
    var openConnections: Int { state.withLock { $0.connections.count } }

    /// Stops listening and closes every connection; requests being answered finish, but their answers go nowhere.
    public func stop() {
        let (listener, connections) = state.withLock { state in
            state.stopped = true
            defer { (state.listener, state.connections) = (nil, [:]) }
            return (state.listener, Array(state.connections.values))
        }
        listener?.cancel()
        for connection in connections { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let accepted = state.withLock { state in
            guard !state.stopped else { return false }
            state.connections[id] = connection
            return true
        }
        guard accepted else { return connection.cancel() }
        connection.start(queue: queue)
        Task {
            await serve(connection)
            connection.cancel()
            state.withLock { _ = $0.connections.removeValue(forKey: id) }
        }
    }

    private func serve(_ connection: NWConnection) async {
        let timer = IdleTimer()
        var buffer = Data()
        timer.arm(closing: connection, after: idleTimeout, on: queue)
        defer { timer.disarm() }
        while true {
            switch parseRequest(buffer) {
            case .incomplete:
                guard let data = await receive(on: connection) else { return }
                buffer.append(data)
            case .invalid(let status):
                // The rest of the stream cannot be framed, so the connection ends with the answer.
                output("[bts] \"<unreadable request>\" \(status)")
                _ = await send(
                    HTTPResponse.error(status).serialized(keepAlive: false, includeBody: true), on: connection)
                return
            case .request(let request, let consumed):
                timer.disarm()  // a proxy fetch may take its 20 s
                buffer = Data(buffer.dropFirst(consumed))
                let response = await handler(request)
                timer.arm(closing: connection, after: idleTimeout, on: queue)  // also bounds a client that never reads
                let keepAlive = request.keepAlive
                let bytes = response.serialized(keepAlive: keepAlive, includeBody: request.method != "HEAD")
                guard await send(bytes, on: connection), keepAlive else { return }
            }
        }
    }

    /// The next bytes; nil at the end of the stream, on an error, or once the connection is cancelled.
    private func receive(on connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                continuation.resume(returning: data.flatMap { $0.isEmpty ? nil : $0 })
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { continuation.resume(returning: $0 == nil) })
        }
    }
}

private struct ServerError: Error, CustomStringConvertible {
    let description: String
}

/// Cancels a connection unless disarmed in time. Firing and disarming take the same lock, so once `disarm` returns the
/// timer can no longer close the connection.
private final class IdleTimer: Sendable {
    private let generation = OSAllocatedUnfairLock(initialState: 0)

    func arm(closing connection: NWConnection, after timeout: DispatchTimeInterval, on queue: DispatchQueue) {
        let armed = generation.withLock {
            $0 += 1
            return $0
        }
        queue.asyncAfter(deadline: .now() + timeout) { [generation] in
            generation.withLock { if $0 == armed { connection.cancel() } }
        }
    }

    func disarm() { generation.withLock { $0 += 1 } }
}
