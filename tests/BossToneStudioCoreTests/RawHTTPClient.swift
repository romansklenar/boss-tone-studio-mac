import Darwin
import Foundation

struct RawHTTPResponse: Sendable {
    let status: Int
    /// Names lower-cased; the first of a repeated header wins.
    let headers: [String: String]
    let body: Data

    var text: String { String(decoding: body, as: UTF8.self) }
}

struct RawHTTPError: Error, CustomStringConvertible {
    let description: String
}

/// One TCP connection to `127.0.0.1:<port>` that sends exactly the bytes it is given: no client library normalises a
/// path, adds a header or fixes the framing, so the tests reach the server's parser and router as an attacker would.
/// Blocking calls, with a 5 s receive timeout so a wedged server fails a test instead of hanging the run.
final class RawHTTPConnection {
    private let socket: Int32
    private var buffer = Data()

    init(port: UInt16) throws {
        socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw RawHTTPError(description: "socket: errno \(errno)") }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(socket)
            throw RawHTTPError(description: "connect: errno \(errno)")
        }
    }

    deinit { Darwin.close(socket) }

    func send(_ bytes: Data) throws {
        var sent = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.send(socket, $0.baseAddress! + sent, bytes.count - sent, 0) }
            guard count > 0 else { throw RawHTTPError(description: "send: errno \(errno)") }
            sent += count
        }
    }

    func send(_ text: String) throws { try send(Data(text.utf8)) }

    /// The next response; `toHead` for an answer to HEAD, which has a length but no body.
    func readResponse(toHead: Bool = false) throws -> RawHTTPResponse {
        let blankLine = Data("\r\n\r\n".utf8)
        while buffer.firstRange(of: blankLine) == nil {
            guard try receive() else { throw RawHTTPError(description: "closed before a response head") }
        }
        let headEnd = buffer.firstRange(of: blankLine)!
        let head = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self)
        buffer = Data(buffer[headEnd.upperBound...])
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, let status = Int(statusLine[1]) else {
            throw RawHTTPError(description: "bad status line in \(head)")
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name] == nil { headers[name] = value }
        }
        let length = toHead || status == 204 || status == 304 ? 0 : Int(headers["content-length"] ?? "0") ?? 0
        while buffer.count < length {
            guard try receive() else { throw RawHTTPError(description: "closed inside a body") }
        }
        let body = Data(buffer.prefix(length))
        buffer = Data(buffer.dropFirst(length))
        return RawHTTPResponse(status: status, headers: headers, body: body)
    }

    /// Whether the server closed the connection (rather than sending more) before the receive timeout.
    func isClosedByServer() throws -> Bool {
        guard buffer.isEmpty else { return false }
        return try !receive()
    }

    /// False at end of stream, closed or reset.
    private func receive() throws -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.recv(socket, &chunk, chunk.count, 0)
        if count < 0 && errno == ECONNRESET { return false }
        if count < 0 {
            throw RawHTTPError(description: errno == EAGAIN ? "no answer within 5 s" : "recv: errno \(errno)")
        }
        buffer.append(contentsOf: chunk.prefix(count))
        return count > 0
    }
}

/// Runs blocking socket work on a GCD thread: on Swift's cooperative pool it would hold a thread the server under test
/// needs to answer, and with tests running in parallel that can starve the pool.
func offThePool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(with: Result { try work() }) }
    }
}

/// Requests the way `tests/test_bridge_http.py` sent them, each on a new connection, with `Host: 127.0.0.1:<port>`
/// unless `headers` names its own.
struct RawHTTPClient: Sendable {
    let port: UInt16

    var host: String { "127.0.0.1:\(port)" }

    /// `bytes` as they are on a new connection, and the one response.
    func exchange(_ bytes: String, toHead: Bool = false) async throws -> RawHTTPResponse {
        try await offThePool {
            let connection = try RawHTTPConnection(port: port)
            try connection.send(bytes)
            return try connection.readResponse(toHead: toHead)
        }
    }

    func request(
        _ method: String, _ target: String, headers: [(String, String)] = [], body: Data? = nil
    ) async throws -> RawHTTPResponse {
        let bytes = Self.bytes(method, target, headers: [("Host", host)] + headers, body: body)
        return try await offThePool {
            let connection = try RawHTTPConnection(port: port)
            try connection.send(bytes)
            return try connection.readResponse(toHead: method == "HEAD")
        }
    }

    func status(_ method: String, _ target: String, headers: [(String, String)] = [], body: Data? = nil)
        async throws -> Int
    {
        try await request(method, target, headers: headers, body: body).status
    }

    /// A command the way the page script sends it: POST with a JSON array of strings, unless `body` replaces it.
    func command(
        _ target: String, _ args: [String] = [], headers: [(String, String)] = [], body: Data? = nil
    ) async throws -> RawHTTPResponse {
        let json = try body ?? JSONSerialization.data(withJSONObject: args)
        return try await request(
            "POST", target, headers: [("Content-Type", "application/json")] + headers, body: json)
    }

    /// The request's bytes. A later header replaces an earlier one of the same name, so `headers` can override the
    /// defaults; `Content-Length` is added for a body unless given.
    static func bytes(_ method: String, _ target: String, headers: [(String, String)], body: Data?) -> Data {
        var merged: [(String, String)] = []
        for (name, value) in headers {
            merged.removeAll { $0.0.lowercased() == name.lowercased() }
            merged.append((name, value))
        }
        if let body, !merged.contains(where: { $0.0.lowercased() == "content-length" }) {
            merged.append(("Content-Length", String(body.count)))
        }
        var head = "\(method) \(target) HTTP/1.1\r\n"
        for (name, value) in merged { head += "\(name): \(value)\r\n" }
        var data = Data((head + "\r\n").utf8)
        if let body { data.append(body) }
        return data
    }
}
