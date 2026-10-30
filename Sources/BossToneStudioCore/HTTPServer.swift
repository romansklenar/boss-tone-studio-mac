import Foundation
import Network
import os

/// HTTP/1.1 on `127.0.0.1` only, at a port the system picks. Each connection answers its requests one at a time and in
/// order; connections run concurrently, so a slow request (a proxy fetch, a pending command) holds up only its own.
/// Keep-alive matters: the page polls `$$app_getevent` every 50 ms with synchronous XHR.
public final class HTTPServer: Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private struct State {
        var listener: NWListener?
        var handler: Handler?
        var connections: [ObjectIdentifier: NWConnection] = [:]
        var stopped = false
    }

    private let idleTimeout: DispatchTimeInterval
    private let output: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "bts.http")
    private let state = OSAllocatedUnfairLock(initialState: State())

    public convenience init() {
        self.init(idleTimeout: .seconds(30)) { print($0) }
    }

    /// A connection is closed after `idleTimeout` without a complete request, so a stalled request (or a head with
    /// bare line feeds, which never completes) cannot hold it forever. `output` prints one log line.
    init(idleTimeout: DispatchTimeInterval, output: @escaping @Sendable (String) -> Void) {
        self.idleTimeout = idleTimeout
        self.output = output
    }

    /// Binds `127.0.0.1:0`, waits until the listener is ready, then answers with the handler `makeHandler` builds for
    /// that port (the router checks `Host` and `Origin` against it) and returns the port.
    public func start(makeHandler: (UInt16) -> Handler) throws -> UInt16 {
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
        guard started else { throw MessageError("the server was already started") }

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
        if case .success = result, let port = listener.port?.rawValue, port != 0 {
            let handler = makeHandler(port)
            state.withLock { $0.handler = handler }
            return port
        }
        stop()
        if case .failure(let error) = result { throw MessageError("cannot listen on 127.0.0.1: \(error)") }
        throw MessageError("cannot listen on 127.0.0.1: no port within 10 s")
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
        // Until `start` returns nobody has been told the port, so a connection without a handler yet is a stranger's.
        let handler = state.withLock { state -> Handler? in
            guard !state.stopped, let handler = state.handler else { return nil }
            state.connections[id] = connection
            return handler
        }
        guard let handler else { return connection.cancel() }
        connection.start(queue: queue)
        Task {
            await serve(connection, handler)
            connection.cancel()
            state.withLock { _ = $0.connections.removeValue(forKey: id) }
        }
    }

    private func serve(_ connection: NWConnection, _ handler: Handler) async {
        let timer = IdleTimer(closing: connection, after: idleTimeout, on: queue)
        defer { timer.cancel() }
        var buffer = Data()
        timer.arm()
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
                timer.disarm()  // a proxy fetch may take up to 60 s
                buffer = Data(buffer.dropFirst(consumed))
                let response = await handler(request)
                timer.arm()  // also bounds a client that never reads
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

/// Cancels a connection unless disarmed in time: one timer per connection, moved on by every `arm`. The firing handler
/// takes the deadline's lock too, so once `disarm` returns the timer can no longer close the connection, and a fire
/// meant for an earlier deadline closes nothing.
private final class IdleTimer: Sendable {
    private let source: DispatchSourceTimer
    private let timeout: DispatchTimeInterval
    private let deadline = OSAllocatedUnfairLock<DispatchTime?>(initialState: nil)  // nil while disarmed

    init(closing connection: NWConnection, after timeout: DispatchTimeInterval, on queue: DispatchQueue) {
        self.timeout = timeout
        source = DispatchSource.makeTimerSource(queue: queue)
        source.setEventHandler { [weak self] in self?.fire(closing: connection) }
        source.resume()  // not scheduled yet, so it does not fire
    }

    func arm() {
        deadline.withLock { deadline in
            let due = DispatchTime.now() + timeout
            deadline = due
            source.schedule(deadline: due)
        }
    }

    func disarm() { deadline.withLock { $0 = nil } }

    /// Once the connection has ended: lets go of the handler and the connection it holds.
    func cancel() { source.cancel() }

    private func fire(closing connection: NWConnection) {
        deadline.withLock { deadline in
            guard let deadline else { return }
            if DispatchTime.now() >= deadline { connection.cancel() } else { source.schedule(deadline: deadline) }
        }
    }
}
