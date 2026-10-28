import Darwin
import Foundation
import UniformTypeIdentifiers

/// Answers requests by the rules of `doc/bridge-protocol.md` › Security, checked in this order: method, `Host`, token,
/// origin, then the route. Everything lives under `/<token>/`, the page and its files included, so nothing on this
/// machine but the page learns the token; the page is `http://127.0.0.1:<port>/<token>/index.html`.
public final class Router: Sendable {
    private let token: String
    private let host: String
    private let origin: String
    /// The web app's folder and its `index.html`, resolved, as every requested path is before it is compared.
    private let root: String
    private let index: String
    private let dispatcher: CommandDispatching
    private let proxy: ProxyFetching
    private let output: @Sendable (String) -> Void

    private static let maxPageLogCharacters = 500

    public convenience init(
        port: UInt16, token: String, htmlDir: URL, dispatcher: CommandDispatching, proxy: ProxyFetching
    ) {
        self.init(port: port, token: token, htmlDir: htmlDir, dispatcher: dispatcher, proxy: proxy) { print($0) }
    }

    /// `output` prints one log line (`[bts] …`, `[js] …`).
    init(
        port: UInt16, token: String, htmlDir: URL, dispatcher: CommandDispatching, proxy: ProxyFetching,
        output: @escaping @Sendable (String) -> Void
    ) {
        self.token = token
        host = "127.0.0.1:\(port)"
        origin = "http://127.0.0.1:\(port)"
        root = resolvedPath(htmlDir.path) ?? htmlDir.standardizedFileURL.path
        index = resolvedPath(root + "/index.html") ?? root + "/index.html"
        self.dispatcher = dispatcher
        self.proxy = proxy
        self.output = output
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let response = await route(request)
        // Successes are noise, and a failing command or an unsupported page has already said why.
        if !(200..<400).contains(response.status) && response.status != 500 {
            output("[bts] \"\(loggable(request.requestLine))\" \(response.status)")
        }
        return response
    }

    /// `$$<object>_<method>`, ASCII only: `^\$\$[a-z]+_[A-Za-z0-9]+$`, checked byte by byte, so neither a trailing
    /// newline nor a letter with a combining mark can pass.
    static func isCommandRoute(_ route: String) -> Bool {
        let bytes = Array(route.utf8)
        guard bytes.starts(with: Array("$$".utf8)), let underscore = bytes.firstIndex(of: UInt8(ascii: "_")) else {
            return false
        }
        let lowercase = UInt8(ascii: "a")...UInt8(ascii: "z")
        let uppercase = UInt8(ascii: "A")...UInt8(ascii: "Z")
        let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
        let object = bytes[2..<underscore]
        let method = bytes[(underscore + 1)...]
        return !object.isEmpty && object.allSatisfy(lowercase.contains) && !method.isEmpty
            && method.allSatisfy { lowercase.contains($0) || uppercase.contains($0) || digits.contains($0) }
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        guard ["GET", "HEAD", "POST"].contains(request.method) else { return .error(501) }
        // DNS rebinding: a page on another name that resolves here sends its own name. A second `Host` could be read
        // differently by something in between, so there must be exactly one.
        let hosts = request.headers.filter { $0.name.lowercased() == "host" }
        guard hosts.count == 1, hosts[0].value == host else { return .error(403) }
        guard let path = pathUnderToken(request.path) else { return .error(403) }
        // Other web pages in the user's browser must neither drive the bridge nor open the editor.
        if let requestOrigin = request.header("Origin"), requestOrigin != origin { return .error(403) }
        if let site = request.header("Sec-Fetch-Site"), site != "same-origin", site != "none" { return .error(403) }

        if path.hasPrefix("$$") { return command(path, request) }
        switch path {
        case "proxy": return await proxied(request)
        case "log": return pageLog(request)
        default: return staticFile(path, request)
        }
    }

    /// The path after `/<token>/`, percent-decoded once; nil when the first segment is not the token. Split as bytes:
    /// a `/` is never part of a longer UTF-8 sequence, while as a `Character` it could carry a combining mark.
    private func pathUnderToken(_ rawPath: String) -> String? {
        let path = percentDecodedBytes(rawPath)
        guard path.first == UInt8(ascii: "/") else { return nil }
        let afterSlash = path.dropFirst()
        let slash = afterSlash.firstIndex(of: UInt8(ascii: "/")) ?? afterSlash.endIndex
        guard constantTimeEquals(String(decoding: afterSlash[..<slash], as: UTF8.self), token) else { return nil }
        return String(decoding: afterSlash[slash...].dropFirst(), as: UTF8.self)
    }

    // MARK: routes

    private func command(_ route: String, _ request: HTTPRequest) -> HTTPResponse {
        guard request.method == "POST" else { return .error(405) }
        guard Self.isCommandRoute(route) else { return .error(404) }
        // A cross-site form cannot send this type without a preflight.
        let mediaType = (request.header("Content-Type") ?? "").prefix { $0 != ";" }
        guard mediaType.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
            return .error(415)
        }
        let args: [String]
        do {
            args = try Self.commandArguments(request.body)
        } catch {
            return .text("\(error)", status: 400)
        }
        let name = String(route.dropFirst(2))
        do {
            let result = try dispatcher.dispatch(name, args)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            let body = try result.map { try encoder.encode($0) } ?? Data("null".utf8)
            return HTTPResponse(status: 200, contentType: "application/json", body: body)
        } catch {
            // The page script throws the body as an Error; the log line is escaped, as errors can carry page paths.
            let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            output("[bts] $$\(name) failed: \(escaped(text))")
            return .text(text, status: 500)
        }
    }

    /// A command's arguments: a JSON array of strings, as the page script sends them.
    static func commandArguments(_ body: Data) throws -> [String] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: body, options: .fragmentsAllowed)
        } catch {
            let reason = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
            throw ArgumentsError(description: reason ?? error.localizedDescription)
        }
        guard let array = value as? [Any], array.allSatisfy({ $0 is String }) else {
            throw ArgumentsError(description: "arguments must be a JSON array of strings")
        }
        return array.compactMap { $0 as? String }
    }

    private func proxied(_ request: HTTPRequest) async -> HTTPResponse {
        switch request.method {
        case "GET": break
        case "POST": return HTTPResponse(status: 204)  // the page's usage telemetry to Roland goes nowhere
        default: return .error(405)
        }
        switch await proxy.fetch(Self.queryValue("url", in: request.query)) {
        case .response(let status, let contentType, let body):
            return HTTPResponse(status: status, contentType: contentType, body: body)
        case .refused(let reason):
            output("[bts] \(reason)")
            return .error(403)
        case .failed(let reason):
            output("[bts] \(reason)")
            return .error(502)
        }
    }

    /// The first non-empty value of `name`, as Python's `parse_qs` reads a query: `+` is a space.
    static func queryValue(_ name: String, in query: String) -> String {
        func decoded(_ text: Substring) -> String { percentDecoded(text.replacingOccurrences(of: "+", with: " ")) }
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, decoded(parts[0]) == name else { continue }
            let value = decoded(parts[1])
            if !value.isEmpty { return value }
        }
        return ""
    }

    /// Page errors, escaped and cut, so the page cannot forge log lines.
    private func pageLog(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == "POST" else { return .error(405) }
        var text = ""
        text.unicodeScalars.append(
            contentsOf: String(decoding: request.body, as: UTF8.self).unicodeScalars.prefix(Self.maxPageLogCharacters))
        output("[js] \(escaped(text))")
        return .text("")
    }

    private func staticFile(_ path: String, _ request: HTTPRequest) -> HTTPResponse {
        if request.method == "POST" { return HTTPResponse(status: 204) }  // the page's usage telemetry goes nowhere
        // A NUL would end the C string `realpath` sees, so `index.html%00.png` would name `index.html`.
        guard !path.unicodeScalars.contains("\0"), let file = resolvedPath(root + "/" + path) else {
            return .error(404)
        }
        // Any spelling of the page (`/`, `./index.html`, `%69ndex.html`…) gets the page with the bridge script.
        if file == index || (fileType(file) == S_IFDIR && resolvedPath(file + "/index.html") == index) {
            return page()
        }
        guard file.hasPrefix(root.hasSuffix("/") ? root : root + "/"), fileType(file) == S_IFREG,
            let body = FileManager.default.contents(atPath: file)
        else { return .error(404) }
        let pathExtension = (file as NSString).pathExtension
        let type = pathExtension.isEmpty ? nil : UTType(filenameExtension: pathExtension)?.preferredMIMEType
        return HTTPResponse(status: 200, contentType: type ?? "application/octet-stream", body: body)
    }

    /// `index.html` with the bridge script, under a policy whose nonce is new for every response.
    private func page() -> HTTPResponse {
        guard let data = FileManager.default.contents(atPath: index) else { return .error(404) }
        let nonce = makeNonce()
        guard let html = String(data: data, encoding: .utf8),
            let page = PageScript.inject(into: html, token: token, nonce: nonce, commands: dispatcher.commands)
        else {
            output("[bts] index.html no longer loads js/lib/native.js; unsupported app version")
            return HTTPResponse(
                status: 500, contentType: "text/html; charset=utf-8", body: Data(PageScript.unsupportedPage.utf8))
        }
        return HTTPResponse(
            status: 200, contentType: "text/html; charset=utf-8", body: Data(page.utf8),
            headers: [("Content-Security-Policy", PageScript.contentSecurityPolicy(nonce: nonce))])
    }

    // MARK: logs

    /// The request line with the token removed in any percent-encoded spelling and control characters escaped (as
    /// `escaped` does, without its quotes), so a failed request neither leaks the token nor forges a log line.
    private func loggable(_ requestLine: String) -> String {
        var text = requestLine
        // Each round undoes one level of encoding; a bound keeps a deeply nested `%25…` from costing a round per byte.
        for _ in 0..<32 {
            let decoded = percentDecoded(text)
            if decoded == text { break }
            text = decoded
        }
        return String(escaped(text.replacingOccurrences(of: token, with: "<token>")).dropFirst().dropLast())
    }
}

struct ArgumentsError: Error, CustomStringConvertible {
    let description: String
}

/// Python's `urllib.parse.unquote` as bytes: valid `%XX` sequences decoded, anything else kept as it is.
private func percentDecodedBytes(_ text: String) -> [UInt8] {
    let input = Array(text.utf8)
    var output: [UInt8] = []
    output.reserveCapacity(input.count)
    var index = 0
    while index < input.count {
        if input[index] == UInt8(ascii: "%"), index + 2 < input.count,
            let high = hexValue(input[index + 1]), let low = hexValue(input[index + 2])
        {
            output.append(high << 4 | low)
            index += 3
        } else {
            output.append(input[index])
            index += 1
        }
    }
    return output
}

/// As Python's `unquote`: bytes that are not UTF-8 become U+FFFD.
private func percentDecoded(_ text: String) -> String {
    String(decoding: percentDecodedBytes(text), as: UTF8.self)
}

private func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
    default: nil
    }
}

/// `realpath`: links, `.` and `..` resolved; nil when the path does not exist.
private func resolvedPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// `S_IFREG`, `S_IFDIR`…, following links; nil when the path does not exist.
private func fileType(_ path: String) -> mode_t? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return info.st_mode & S_IFMT
}
