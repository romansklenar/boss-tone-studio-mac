import Foundation
import Security

// MARK: requests

public struct HTTPRequest: Sendable {
    public let method: String
    public let target: String
    public let version: String
    public let headers: [(name: String, value: String)]
    public let body: Data

    /// The target before the first `?`, raw: percent-decoding is the router's job.
    public var path: String { String(target.prefix { $0 != "?" }) }

    /// The target after the first `?`, raw; empty when there is none.
    public var query: String {
        guard let mark = target.firstIndex(of: "?") else { return "" }
        return String(target[target.index(after: mark)...])
    }

    /// The first header of that name, in any letter case.
    public func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        return headers.first { $0.name.lowercased() == wanted }?.value
    }

    /// Whether the connection may carry another request: HTTP/1.1 does unless a `Connection` header says `close`.
    public var keepAlive: Bool {
        guard version != "HTTP/1.0" else { return false }
        let tokens = headers.filter { $0.name.lowercased() == "connection" }
            .flatMap { $0.value.split(separator: ",") }
            .map { $0.trimmingCharacters(in: optionalWhitespace).lowercased() }
        return !tokens.contains("close")
    }

    /// The request line as received, for logs (the caller redacts and escapes it).
    public var requestLine: String { "\(method) \(target) \(version)" }
}

public enum ParseResult: Sendable {
    case incomplete
    case request(HTTPRequest, consumed: Int)
    case invalid(status: Int)
}

/// Reads one request from the front of `buffer`, the bytes received so far on a connection.
///
/// Strict on purpose: this is the first thing a local web page's bytes reach. Anything that could be read two ways
/// (a bare line feed, a folded header, a repeated or odd `Content-Length`, a `Transfer-Encoding`, a second header the
/// router decides by, a raw byte from 0x80 up in the target) is refused.
public func parseRequest(
    _ buffer: Data, maxHeaderBytes: Int = 65_536, maxBodyBytes: Int = 67_108_864
) -> ParseResult {
    // Only the head can be this long; looking further would make a huge body cost a scan per call.
    let head = Array(buffer.prefix(maxHeaderBytes))
    guard let headEnd = indexAfterBlankLine(head) else {
        return buffer.count > maxHeaderBytes ? .invalid(status: 400) : .incomplete
    }
    guard let lines = headLines(head[..<(headEnd - 4)]), let requestLine = parseRequestLine(lines[0]),
        let (headers, lengths) = parseHeaders(lines.dropFirst())
    else { return .invalid(status: 400) }
    let names = headers.map { $0.name.lowercased() }
    guard !names.contains("transfer-encoding"),
        singleHeaders.allSatisfy({ single in names.count { $0 == single } <= 1 }),
        let length = bodyLength(lengths, limit: maxBodyBytes)
    else { return .invalid(status: 400) }
    guard buffer.count - headEnd >= length else { return .incomplete }
    let body = Data(buffer.dropFirst(headEnd).prefix(length))
    let request = HTTPRequest(
        method: requestLine.method, target: requestLine.target, version: requestLine.version, headers: headers,
        body: body)
    return .request(request, consumed: headEnd + length)
}

private let cr = UInt8(ascii: "\r")
private let lf = UInt8(ascii: "\n")
private let space = UInt8(ascii: " ")
private let tab = UInt8(ascii: "\t")

/// HTTP's optional whitespace: space and tab only, not the Unicode spaces `.whitespaces` adds.
private let optionalWhitespace = CharacterSet(charactersIn: " \t")

/// The headers the router decides by; it reads the first, so a second one could be read differently elsewhere.
private let singleHeaders = ["host", "origin", "sec-fetch-site", "content-type"]

/// The index just past the first CRLFCRLF.
private func indexAfterBlankLine(_ bytes: [UInt8]) -> Int? {
    guard bytes.count >= 4 else { return nil }
    for start in 0...(bytes.count - 4)
    where bytes[start] == cr && bytes[start + 1] == lf && bytes[start + 2] == cr && bytes[start + 3] == lf {
        return start + 4
    }
    return nil
}

/// The head's lines, split at CRLF; nil when a line holds a bare CR or LF or a NUL.
private func headLines(_ head: ArraySlice<UInt8>) -> [ArraySlice<UInt8>]? {
    var lines: [ArraySlice<UInt8>] = []
    var start = head.startIndex
    var index = start
    while index < head.endIndex {
        if head[index] == cr, index + 1 < head.endIndex, head[index + 1] == lf {
            lines.append(head[start..<index])
            index += 2
            start = index
        } else {
            index += 1
        }
    }
    lines.append(head[start...])
    return lines.contains { $0.contains { $0 == cr || $0 == lf || $0 == 0 } } ? nil : lines
}

/// Header bytes as ISO-8859-1, the one-to-one reading, so decoding cannot fail or differ from the bytes' meaning.
private func latin1(_ bytes: ArraySlice<UInt8>) -> String {
    String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
}

private func isTokenCharacter(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
        UInt8(ascii: "a")...UInt8(ascii: "z"):
        true
    default:
        "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }
}

private func parseRequestLine(_ line: ArraySlice<UInt8>) -> (method: String, target: String, version: String)? {
    let parts = line.split(separator: space, omittingEmptySubsequences: false)
    guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
    let (method, target, version) = (parts[0], parts[1], parts[2])
    let versionText = latin1(version)  // HTTP/1.x
    // Visible ASCII only (RFC 9112): raw bytes from 0x80 up have no agreed encoding, and XHR percent-encodes them.
    guard method.allSatisfy(isTokenCharacter), target.allSatisfy({ $0 > 0x20 && $0 < 0x7F }),
        versionText.hasPrefix("HTTP/1."), version.count == 8, version.last.map(isDigit) == true
    else { return nil }
    return (latin1(method), latin1(target), versionText)
}

private func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }

/// The headers, and the raw text of every `Content-Length` (what follows the colon, less one optional space).
private func parseHeaders(
    _ lines: ArraySlice<ArraySlice<UInt8>>
) -> (headers: [(name: String, value: String)], contentLengths: [ArraySlice<UInt8>])? {
    var headers: [(name: String, value: String)] = []
    var lengths: [ArraySlice<UInt8>] = []
    for line in lines {
        guard let first = line.first, first != space, first != tab,  // no folded lines
            let colon = line.firstIndex(of: UInt8(ascii: ":")), colon > line.startIndex,
            line[..<colon].allSatisfy(isTokenCharacter)  // also refuses a space before the colon
        else { return nil }
        let name = latin1(line[..<colon])
        var value = line[(colon + 1)...]
        while let last = value.last, last == space || last == tab { value = value.dropLast() }
        if name.lowercased() == "content-length" { lengths.append(value.first == space ? value.dropFirst() : value) }
        headers.append((name, latin1(value).trimmingCharacters(in: optionalWhitespace)))
    }
    return (headers, lengths)
}

/// The declared body length: ASCII digits only, one value (repeats must agree), within `limit`. No header means 0.
private func bodyLength(_ raws: [ArraySlice<UInt8>], limit: Int) -> Int? {
    var lengths = Set<Int>()
    for raw in raws {
        guard !raw.isEmpty, raw.count <= 18, raw.allSatisfy(isDigit),
            let value = Int(latin1(raw))
        else { return nil }
        lengths.insert(value)
    }
    guard lengths.count <= 1 else { return nil }
    let length = lengths.first ?? 0
    return length <= limit ? length : nil
}

// MARK: responses

public struct HTTPResponse: Sendable {
    public let status: Int
    public let contentType: String?
    public let body: Data
    public let headers: [(String, String)]

    public init(status: Int, contentType: String? = nil, body: Data = Data(), headers: [(String, String)] = []) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.headers = headers
    }

    public static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    /// `<status> <reason>` as plain text.
    public static func error(_ status: Int) -> HTTPResponse {
        text("\(status) \(reasonPhrase(status))", status: status)
    }

    /// The bytes to send. `headers` come first, then the ones every response gets: framing (`Content-Length`, and
    /// `Connection: close` unless the connection stays), no caching, no framing in a frame, no content sniffing, and
    /// `frame-ancestors 'none'` unless the response sets a policy of its own. The response owns its framing, so
    /// `headers` named `Content-Length`, `Transfer-Encoding` or `Connection` are dropped, and CR, LF and NUL in any
    /// header are replaced by spaces: a content type that came from a remote server cannot split the response.
    /// `includeBody: false` is for HEAD: the headers a GET would get, no body.
    public func serialized(keepAlive: Bool, includeBody: Bool) -> Data {
        // 1xx, 204 and 304 carry neither a body nor a Content-Length (RFC 9110, 8.6 and 15.3.5).
        let hasNoBody = status == 204 || status == 304 || (100..<200).contains(status)
        let owned: Set<String> = ["content-length", "transfer-encoding", "connection"]
        var fields = headers.filter { !owned.contains($0.0.lowercased()) }
        if let contentType { fields.insert(("Content-Type", contentType), at: 0) }
        if !hasNoBody { fields.append(("Content-Length", String(body.count))) }
        fields.append(("Cache-Control", "no-store"))
        fields.append(("X-Frame-Options", "DENY"))
        fields.append(("X-Content-Type-Options", "nosniff"))
        if !fields.contains(where: { $0.0.lowercased() == "content-security-policy" }) {
            fields.append(("Content-Security-Policy", "frame-ancestors 'none'"))
        }
        if !keepAlive { fields.append(("Connection", "close")) }

        var head = "HTTP/1.1 \(status) \(HTTPResponse.reasonPhrase(status))\r\n"
        for (name, value) in fields { head += "\(Self.singleLine(name)): \(Self.singleLine(value))\r\n" }
        var data = Data((head + "\r\n").utf8)
        if includeBody && !hasNoBody { data.append(body) }
        return data
    }

    private static func singleLine(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { $0 == "\r" || $0 == "\n" || $0 == "\0" ? " " : $0 }))
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 304: "Not Modified"
        case 307: "Temporary Redirect"
        case 308: "Permanent Redirect"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 415: "Unsupported Media Type"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: "Status \(status)"
        }
    }
}

// MARK: secrets

private func randomBytes(_ count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    // A predictable token would void the bridge's access control, so there is no fallback.
    precondition(status == errSecSuccess, "no secure random bytes (\(status))")
    return Data(bytes)
}

/// The per-launch token in the page's URLs: 24 random bytes as 32 URL-safe characters.
public func makeToken() -> String {
    randomBytes(24).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// The script nonce, new for every page response: 16 random bytes, base64 (what a CSP nonce is).
public func makeNonce() -> String {
    randomBytes(16).base64EncodedString()
}

/// Compares without stopping at the first difference. Equal length is not hidden: the token's is public.
public func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let (x, y) = (Array(a.utf8), Array(b.utf8))
    var difference = x.count ^ y.count
    for index in 0..<max(x.count, y.count) {
        difference |= Int((index < x.count ? x[index] : 0) ^ (index < y.count ? y[index] : 0))
    }
    return difference == 0
}
