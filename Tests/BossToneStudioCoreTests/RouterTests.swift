import Foundation
import Testing
import os

@testable import BossToneStudioCore

// The security rules of doc/bridge-protocol.md and the design's fixes (127.0.0.1 only, everything under the token, a
// CSP with a nonce), over a real loopback server with a stand-in bridge and proxy: the port of 0.1.1's Python
// HTTP tests.

private let token = "test-token"

private struct Refused: Error {}

private final class RecordingDispatcher: CommandDispatching {
    private struct State {
        var calls: [Call] = []
        var result: String? = "ok"
        var failure: (any Error & Sendable)?
    }

    struct Call: Equatable {
        let command: String
        let args: [String]
    }

    let commands = ["app_storage2", "midi_send"]
    private let state = OSAllocatedUnfairLock(initialState: State())

    var calls: [Call] { state.withLock { $0.calls } }

    func answer(_ result: String?) { state.withLock { $0.result = result } }

    func fail(with error: any Error & Sendable) { state.withLock { $0.failure = error } }

    func dispatch(_ command: String, _ args: [String]) throws -> String? {
        let (result, failure) = state.withLock {
            $0.calls.append(Call(command: command, args: args))
            return ($0.result, $0.failure)
        }
        if let failure { throw failure }
        return result
    }
}

private final class StubProxy: ProxyFetching {
    private let answer: @Sendable (String) async -> ProxyResult
    private let fetched = OSAllocatedUnfairLock(initialState: [String]())

    init(_ answer: @escaping @Sendable (String) async -> ProxyResult = { _ in .failed("unexpected fetch") }) {
        self.answer = answer
    }

    var urls: [String] { fetched.withLock { $0 } }

    func fetch(_ url: String) async -> ProxyResult {
        fetched.withLock { $0.append(url) }
        return await answer(url)
    }
}

/// What the router printed, line by line.
private final class LogLines: Sendable {
    private let lines = OSAllocatedUnfairLock(initialState: [String]())

    var all: [String] { lines.withLock { $0 } }

    func append(_ line: String) { lines.withLock { $0.append(line) } }
}

private let nativeJS = "window.native = true;\n"

/// A web root in a fresh folder (`<folder>/html`, a small `index.html` and `js/lib/native.js`, never Roland's files)
/// served on a real loopback port until `stop()`.
private struct TestServer {
    let client: RawHTTPClient
    let html: URL
    let dispatcher: RecordingDispatcher
    let proxy: StubProxy
    let log = LogLines()
    private let server: HTTPServer

    var port: UInt16 { client.port }
    var origin: String { "http://127.0.0.1:\(port)" }

    init(dispatcher: RecordingDispatcher = RecordingDispatcher(), proxy: StubProxy = StubProxy()) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bts-test-\(UUID().uuidString)")
        let html = folder.appendingPathComponent("html")
        try FileManager.default.createDirectory(
            at: html.appendingPathComponent("js/lib"), withIntermediateDirectories: true)
        try "<html>\(PageScript.nativeScriptTag)</html>".write(
            to: html.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try nativeJS.write(to: html.appendingPathComponent("js/lib/native.js"), atomically: true, encoding: .utf8)

        let log = log
        let server = HTTPServer(idleTimeout: .seconds(30), output: log.append)
        let port = try server.start { port in
            let router = Router(
                port: port, token: token, htmlDir: html, dispatcher: dispatcher, proxy: proxy, output: log.append)
            return { await router.handle($0) }
        }
        (self.server, self.html, self.dispatcher, self.proxy) = (server, html, dispatcher, proxy)
        client = RawHTTPClient(port: port)
    }

    func stop() {
        server.stop()
        try? FileManager.default.removeItem(at: html.deletingLastPathComponent())
    }
}

// MARK: commands

@Test func commandWithTokenReachesTheBridgeAndAnswersJSON() async throws {
    let server = try TestServer()
    defer { server.stop() }
    let response = try await server.client.command("/\(token)/$$app_storage2", ["key", ","])
    #expect(response.status == 200)
    #expect(response.text == #""ok""#)
    #expect(response.headers["content-type"] == "application/json")
    #expect(server.dispatcher.calls == [.init(command: "app_storage2", args: ["key", ","])])
}

@Test func resultsAreJSONStrings() async throws {
    let dispatcher = RecordingDispatcher()
    dispatcher.answer("a/\"b\"\n€")
    let server = try TestServer(dispatcher: dispatcher)
    defer { server.stop() }
    let response = try await server.client.command("/\(token)/$$app_storage2", ["k"])
    #expect(
        try JSONSerialization.jsonObject(with: response.body, options: .fragmentsAllowed) as? String
            == "a/\"b\"\n€")
}

@Test func noResultAnswersNull() async throws {
    let dispatcher = RecordingDispatcher()
    dispatcher.answer(nil)
    let server = try TestServer(dispatcher: dispatcher)
    defer { server.stop() }
    let response = try await server.client.command("/\(token)/$$app_getevent")
    #expect(response.status == 200)
    #expect(response.text == "null")
}

@Test func aFailingCommandAnswers500WithItsMessage() async throws {
    let dispatcher = RecordingDispatcher()
    dispatcher.fail(with: BridgeError(description: "refused\n[bts] forged"))
    let server = try TestServer(dispatcher: dispatcher)
    defer { server.stop() }
    let response = try await server.client.command("/\(token)/$$fs_exec", ["file:///"])
    #expect(response.status == 500)
    #expect(response.text == "refused\n[bts] forged")
    // Escaped, and logged once: the router's failed-request line leaves a 500 to this one.
    #expect(server.log.all == [#"[bts] $$fs_exec failed: 'refused\n[bts] forged'"#])
}

@Test func anErrorWithoutADescriptionAnswersItsName() async throws {
    let dispatcher = RecordingDispatcher()
    dispatcher.fail(with: Refused())
    let server = try TestServer(dispatcher: dispatcher)
    defer { server.stop() }
    let response = try await server.client.command("/\(token)/$$fs_exec", ["file:///"])
    #expect(response.status == 500)
    #expect(response.text == "Refused()")
}

@Test func commandWithoutOrWithAWrongTokenIsRefused() async throws {
    let server = try TestServer()
    defer { server.stop() }
    for path in ["/$$app_storage", "/wrong/$$app_storage", "/%C3%A9/$$app_storage", "/test-tokens/$$app_storage"] {
        #expect(try await server.client.command(path).status == 403, "\(path)")
    }
    #expect(try await server.client.status("GET", "/wrong/proxy?url=x") == 403)
    #expect(server.dispatcher.calls.isEmpty)
    #expect(server.proxy.urls.isEmpty)
}

@Test func commandsArePostOnly() async throws {
    let server = try TestServer()
    defer { server.stop() }
    #expect(try await server.client.status("GET", "/\(token)/$$app_storage") == 405)
    #expect(try await server.client.status("HEAD", "/\(token)/$$app_storage") == 405)
    #expect(server.dispatcher.calls.isEmpty)
}

@Test func commandNamesAreObjectUnderscoreMethod() async throws {
    let server = try TestServer()
    defer { server.stop() }
    for name in ["$$app", "$$App_x", "$$app_x_y", "$$app_", "$$_x", "$$app_x%0a", "$$app_x%20", "$$app_%C3%A9"] {
        #expect(try await server.client.command("/\(token)/\(name)").status == 404, "\(name)")
    }
    #expect(server.dispatcher.calls.isEmpty)
}

@Test func commandsNeedJSONArgumentsOfStrings() async throws {
    let server = try TestServer()
    defer { server.stop() }
    let path = "/\(token)/$$app_storage2"
    // What a cross-site form could send without a preflight, and no type at all.
    #expect(try await server.client.command(path, ["k", "v"], headers: [("Content-Type", "text/plain")]).status == 415)
    let untyped = "POST \(path) HTTP/1.1\r\nHost: \(server.client.host)\r\nContent-Length: 5\r\n\r\n[\"k\"]"
    #expect(try await server.client.exchange(untyped).status == 415)
    for body in ["not json", #"{"k": "v"}"#, #"[3, ""]"#, "[null]", #""k""#, String(repeating: "[", count: 100_000)] {
        let response = try await server.client.command("/\(token)/$$app_x", body: Data(body.utf8))
        #expect(response.status == 400, "\(body.prefix(10))")
        #expect(!response.text.isEmpty)
    }
    #expect(server.dispatcher.calls.isEmpty)
}

@Test func theMediaTypeIsReadWithoutParametersOrCase() async throws {
    let server = try TestServer()
    defer { server.stop() }
    for type in ["application/json; charset=utf-8", "Application/JSON", "application/json ;x=y"] {
        #expect(
            try await server.client.command("/\(token)/$$app_storage2", headers: [("Content-Type", type)])
                .status == 200, "\(type)")
    }
}

@Test func everyCommandNamePassesTheRouteCheck() throws {
    try withTemporaryFolder { folder in
        let bridge = try Bridge(dataDir: folder, midiBackend: nil, openURL: { _ in })
        defer { bridge.removeTempDir() }
        #expect(!bridge.commands.isEmpty)
        for command in bridge.commands {
            #expect(Router.isCommandRoute("$$\(command)"), "\(command)")
        }
    }
}

// MARK: Host, token, origin

@Test func otherMethodsAreNotImplemented() async throws {
    let server = try TestServer()
    defer { server.stop() }
    for method in ["PUT", "DELETE", "OPTIONS", "PATCH", "get"] {
        #expect(try await server.client.status(method, "/\(token)/index.html") == 501, "\(method)")
    }
}

@Test func foreignHostIsRefusedForEveryMethod() async throws {
    let server = try TestServer()
    defer { server.stop() }
    let foreign = [("Host", "evil.example:\(server.port)")]
    #expect(try await server.client.command("/\(token)/$$app_storage", headers: foreign).status == 403)
    for method in ["GET", "HEAD"] {
        #expect(try await server.client.status(method, "/\(token)/index.html", headers: foreign) == 403)
    }
    #expect(try await server.client.status("GET", "/\(token)/index.html", headers: [("Host", "127.0.0.1")]) == 403)
    #expect(server.dispatcher.calls.isEmpty)
}

@Test func localhostAndIPv6NamesAreRefused() async throws {
    let server = try TestServer()
    defer { server.stop() }
    for host in ["localhost:\(server.port)", "[::1]:\(server.port)"] {
        #expect(try await server.client.status("GET", "/\(token)/index.html", headers: [("Host", host)]) == 403)
        #expect(try await server.client.command("/\(token)/$$app_storage2", headers: [("Host", host)]).status == 403)
    }
    let localOrigin = [("Origin", "http://localhost:\(server.port)")]
    #expect(try await server.client.command("/\(token)/$$app_storage2", headers: localOrigin).status == 403)
    #expect(server.dispatcher.calls.isEmpty)
}

@Test func aMissingHostIsRefusedAndARepeatedOneUnreadable() async throws {
    let server = try TestServer()
    defer { server.stop() }
    let path = "/\(token)/index.html"
    #expect(try await server.client.exchange("GET \(path) HTTP/1.1\r\n\r\n").status == 403)
    let host = server.client.host
    let twice = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nHost: evil.example\r\n\r\n"
    #expect(try await server.client.exchange(twice).status == 400)
    let reversed = "GET \(path) HTTP/1.1\r\nHost: evil.example\r\nhost: \(host)\r\n\r\n"
    #expect(try await server.client.exchange(reversed).status == 400)
}

@Test func requestsThatCouldBeReadTwoWaysNeverReachTheBridge() async throws {
    let server = try TestServer()
    defer { server.stop() }
    let path = "/\(token)/$$app_storage2"
    let head = "POST \(path) HTTP/1.1\r\nHost: \(server.client.host)\r\nContent-Length: 2\r\n"
    for repeated in [
        "Origin: \(server.origin)\r\nOrigin: https://evil.example\r\n",
        "Sec-Fetch-Site: same-origin\r\nSec-Fetch-Site: cross-site\r\n",
        "Content-Type: application/json\r\nContent-Type: text/plain\r\n",
    ] {
        #expect(try await server.client.exchange(head + repeated + "\r\n[]").status == 400, "\(repeated)")
    }
    let raw = "GET /\(token)/caf\u{E9}.html HTTP/1.1\r\nHost: \(server.client.host)\r\n\r\n"
    #expect(try await server.client.exchange(raw).status == 400)
    #expect(server.dispatcher.calls.isEmpty)
}

@Test func nearMissesOfTheTokenAreRefused() async throws {
    let server = try TestServer()
    defer { server.stop() }
    let split = "\(token.prefix(4))%2F\(token.dropFirst(4))"
    for segment in [String(token.dropLast()), token.uppercased(), "%2F\(token)", split] {
        #expect(try await server.client.command("/\(segment)/$$app_storage2").status == 403, "\(segment)")
        #expect(try await server.client.status("GET", "/\(segment)/index.html") == 403, "\(segment)")
    }
    for path in ["/", "/index.html", "/js/lib/native.js"] {
        #expect(try await server.client.status("HEAD", path) == 403, "\(path)")
    }
    #expect(server.dispatcher.calls.isEmpty)
    // The path is decoded once before it is split, as in 0.1.1: this is `/<token>/…`, the whole token, by design.
    #expect(try await server.client.command("/\(token)%2F$$app_storage2").status == 200)
}

@Test func otherOriginsAreRefused() async throws {
    let server = try TestServer()
    defer { server.stop() }
    for headers in [
        [("Origin", "https://evil.example")], [("Origin", "null")], [("Origin", "\(server.origin)/")],
        [("Sec-Fetch-Site", "cross-site")], [("Sec-Fetch-Site", "same-site")],
    ] {
        #expect(
            try await server.client.command("/\(token)/$$app_storage2", ["k", "v"], headers: headers).status
                == 403)
        #expect(try await server.client.status("GET", "/\(token)/index.html", headers: headers) == 403)
        #expect(try await server.client.status("GET", "/\(token)/js/lib/native.js", headers: headers) == 403)
    }
    #expect(server.dispatcher.calls.isEmpty)
}

@Test func thePagesOwnOriginIsAccepted() async throws {
    let server = try TestServer()
    defer { server.stop() }
    for site in ["same-origin", "none"] {
        let page = [("Origin", server.origin), ("Sec-Fetch-Site", site)]
        #expect(try await server.client.command("/\(token)/$$app_storage2", ["3", ""], headers: page).status == 200)
    }
}

// MARK: logs

@Test func failedRequestsAreLoggedWithoutTheToken() async throws {
    let server = try TestServer()
    defer { server.stop() }
    let evil = [("Origin", "https://evil.example")]
    for spelling in [token, "%74" + token.dropFirst(), "%2574" + token.dropFirst()] {  // plain, encoded, twice
        #expect(try await server.client.command("/\(spelling)/$$app_storage2", headers: evil).status == 403)
    }
    #expect(try await server.client.status("GET", "/\(token)/proxy/") == 404)  // no known route
    #expect(try await server.client.status("GET", "/\(token)/missing.html?t=\(token)") == 404)
    let lines = server.log.all
    #expect(lines.filter { $0.hasSuffix(" 403") }.count == 3)
    #expect(lines.filter { $0.hasSuffix(" 404") }.count == 2)
    #expect(lines.allSatisfy { !$0.contains(token.dropFirst()) })
    #expect(lines.contains(#"[bts] "POST /<token>/$$app_storage2 HTTP/1.1" 403"#))
    #expect(lines.contains(#"[bts] "GET /<token>/missing.html?t=<token> HTTP/1.1" 404"#))
}

@Test func successesAreNotLogged() async throws {
    let server = try TestServer()
    defer { server.stop() }
    #expect(try await server.client.status("GET", "/\(token)/index.html") == 200)
    #expect(try await server.client.command("/\(token)/$$app_storage2").status == 200)
    #expect(try await server.client.status("POST", "/\(token)/index.html", body: Data("stats".utf8)) == 204)
    #expect(server.log.all.isEmpty)
}

@Test func requestPathsCannotForgeLogLines() async throws {
    let server = try TestServer()
    defer { server.stop() }
    #expect(try await server.client.command("/\(token)/$$x%0a[bts]%20forged").status == 404)
    #expect(try await server.client.status("GET", "/\(token)/x%0a[bts]%20forged") == 404)
    #expect(try await server.client.status("GET", "/x%0D%0A[bts]%20forged") == 403)
    #expect(try await server.client.status("GET", "/\(token)/x%C2%85[bts]%20forged") == 404)  // NEL
    let lines = server.log.all
    #expect(lines.count == 4)
    #expect(lines.allSatisfy { !$0.contains("\n") && !$0.contains("\r") && !$0.contains("\u{85}") })
    #expect(lines.contains(#"[bts] "GET /<token>/x\n[bts] forged HTTP/1.1" 404"#))
    #expect(server.dispatcher.calls.isEmpty)
}

@Test func pageLogLinesNeedTheTokenAndAreEscaped() async throws {
    let server = try TestServer()
    defer { server.stop() }
    #expect(try await server.client.status("POST", "/wrong/log", body: Data("x".utf8)) == 403)
    let response = try await server.client.request("POST", "/\(token)/log", body: Data("boom\n[bts] forged".utf8))
    #expect(response.status == 200)
    #expect(response.body.isEmpty)
    #expect(server.log.all.last == #"[js] 'boom\n[bts] forged'"#)
    #expect(try await server.client.status("GET", "/\(token)/log") == 405)
}

@Test func pageLogLinesLeaveTheTokenOut() async throws {
    let server = try TestServer()
    defer { server.stop() }
    // What the error listener sends: `e.filename` is a URL of the page, under the token.
    let error = "boom @ \(server.origin)/\(token)/js/app.js:3 (%74\(token.dropFirst()), %2574\(token.dropFirst()))"
    #expect(try await server.client.status("POST", "/\(token)/log", body: Data(error.utf8)) == 200)
    // Redacted before the cut, so no part of the token is left at the end of a long line.
    let long = String(repeating: "a", count: 495) + token
    #expect(try await server.client.status("POST", "/\(token)/log", body: Data(long.utf8)) == 200)
    #expect(
        server.log.all == [
            "[js] 'boom @ \(server.origin)/<token>/js/app.js:3 (<token>, <token>)'",
            "[js] '\(String(repeating: "a", count: 495))<toke'",
        ])
}

@Test func pageLogLinesAreCutAt500CodePoints() async throws {
    let server = try TestServer()
    defer { server.stop() }
    let text = String(repeating: "é", count: 600)  // two UTF-8 bytes each
    #expect(try await server.client.status("POST", "/\(token)/log", body: Data(text.utf8)) == 200)
    #expect(server.log.all == ["[js] '\(String(repeating: "é", count: 500))'"])
}

// MARK: requests the parser refuses

@Test func postWithABadLengthIsRefusedAndTheConnectionClosed() async throws {
    let server = try TestServer()
    defer { server.stop() }
    for length in ["-1", "abc", String(64 * 1024 * 1024 + 1)] {
        let bytes = RawHTTPClient.bytes(
            "POST", "/\(token)/$$app_x", headers: [("Host", server.client.host), ("Content-Length", length)],
            body: nil)
        let (status, closed) = try await offThePool {
            let connection = try RawHTTPConnection(port: server.port)
            try connection.send(bytes)
            let status = try connection.readResponse().status
            return (status, try connection.isClosedByServer())
        }
        #expect(status == 400, "\(length)")
        #expect(closed, "\(length)")
    }
    #expect(server.dispatcher.calls.isEmpty)
    #expect(server.log.all == Array(repeating: #"[bts] "<unreadable request>" 400"#, count: 3))
}

@Test func theHandlerIsBuiltForThePortTheServerListensOn() async throws {
    let server = HTTPServer(idleTimeout: .seconds(30), output: { _ in })
    defer { server.stop() }
    var built: UInt16?
    let port = try server.start { port in
        built = port
        return { _ in .text("") }
    }
    #expect(built == port)
    #expect(try await RawHTTPClient(port: port).status("GET", "/") == 200)
}

@Test func aStalledRequestIsDroppedAfterTheIdleTimeout() async throws {
    let server = HTTPServer(idleTimeout: .milliseconds(300), output: { _ in })
    let port = try server.start { _ in { _ in .text("") } }
    defer { server.stop() }
    // Half a head, and a head with bare line feeds, which never completes.
    for bytes in ["GET / HTTP/1.1\r\nHost: x", "GET / HTTP/1.1\nHost: x\n\n"] {
        let (closed, released) = try await offThePool {
            let connection = try RawHTTPConnection(port: port)
            try connection.send(bytes)
            let closed = try connection.isClosedByServer()
            // The server lets go as well, while this end is still open: the receive it waited in ends, and its task.
            for _ in 0..<100 where server.openConnections > 0 { usleep(10_000) }
            return (closed, server.openConnections == 0)
        }
        #expect(closed)
        #expect(released)
    }
}

@Test func aConnectionLeftIdleAfterARequestIsDroppedAfterTheIdleTimeout() async throws {
    let server = HTTPServer(idleTimeout: .milliseconds(300), output: { _ in })
    let port = try server.start { _ in { _ in .text("") } }
    defer { server.stop() }
    let (status, closed, waited, released) = try await offThePool {
        let connection = try RawHTTPConnection(port: port)
        try connection.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n")  // keep-alive
        let status = try connection.readResponse().status
        let start = ContinuousClock.now
        let closed = try connection.isClosedByServer()
        let waited = ContinuousClock.now - start
        for _ in 0..<100 where server.openConnections > 0 { usleep(10_000) }
        return (status, closed, waited, server.openConnections == 0)
    }
    #expect(status == 200)
    #expect(closed)
    #expect(waited > .milliseconds(150), "closed by the idle timer, not at once")
    #expect(released)
}

// MARK: proxy and telemetry

@Test func telemetryPostsAreDropped() async throws {
    let server = try TestServer()
    defer { server.stop() }
    #expect(try await server.client.status("POST", "/\(token)/index.html", body: Data("stats".utf8)) == 204)
    let url = "https%3A%2F%2Fapi.roland.com%2Fapp%2Fbtc%2F1%2Fstatuslogs%2F"
    #expect(try await server.client.status("POST", "/\(token)/proxy?url=\(url)", body: Data("stats".utf8)) == 204)
    // As in 0.1.1, any other path under the token takes it too, a file there or not.
    for path in ["js/lib/native.js", "missing/stats", ""] {
        #expect(try await server.client.status("POST", "/\(token)/\(path)", body: Data("stats".utf8)) == 204, "\(path)")
    }
    #expect(try await server.client.status("POST", "/index.html", body: Data("stats".utf8)) == 403)
    #expect(server.dispatcher.calls.isEmpty)
    #expect(server.proxy.urls.isEmpty)
}

@Test func theProxyFetchesTheURLParameter() async throws {
    let proxy = StubProxy { _ in .response(status: 200, contentType: "application/json", body: Data("{}".utf8)) }
    let server = try TestServer(proxy: proxy)
    defer { server.stop() }
    let url = "https%3A%2F%2Fapi.roland.com%2Fx%3Fa%3D1%26b%3D2"
    let response = try await server.client.request("GET", "/\(token)/proxy?x=1&url=\(url)&url=second")
    #expect(response.status == 200)
    #expect(response.headers["content-type"] == "application/json")
    #expect(response.text == "{}")
    #expect(try await server.client.status("HEAD", "/\(token)/proxy?url=\(url)") == 405)
    #expect(proxy.urls == ["https://api.roland.com/x?a=1&b=2"])
}

@Test func proxyRefusalsAndFailuresMapTo403And502() async throws {
    let proxy = StubProxy { url in
        url.contains("evil") ? .refused("refusing to proxy 'https://evil.example/'") : .failed("proxy 'x' failed: down")
    }
    let server = try TestServer(proxy: proxy)
    defer { server.stop() }
    #expect(try await server.client.status("GET", "/\(token)/proxy?url=https%3A%2F%2Fevil.example%2F") == 403)
    #expect(try await server.client.status("GET", "/\(token)/proxy?url=x") == 502)
    let lines = server.log.all
    #expect(lines.filter { $0 == "[bts] refusing to proxy 'https://evil.example/'" }.count == 1)
    #expect(lines.filter { $0 == "[bts] proxy 'x' failed: down" }.count == 1)
}

@Test func theProxysStatusAndBodyPassThrough() async throws {
    let proxy = StubProxy { _ in .response(status: 404, contentType: "text/plain; charset=utf-8", body: Data()) }
    let server = try TestServer(proxy: proxy)
    defer { server.stop() }
    let response = try await server.client.request("GET", "/\(token)/proxy?url=x")
    #expect(response.status == 404)
    #expect(response.headers["content-type"] == "text/plain; charset=utf-8")
    #expect(response.body.isEmpty)
}

// MARK: the page and its files

@Test func theBarePageAndBareFilesAreRefused() async throws {
    let server = try TestServer()
    defer { server.stop() }
    for path in ["/", "/index.html", "/js/lib/native.js", "//index.html", "/./\(token)/index.html"] {
        #expect(try await server.client.status("GET", path) == 403, "\(path)")
    }
}

@Test func staticFilesAreServedUnderTheToken() async throws {
    let server = try TestServer()
    defer { server.stop() }
    let response = try await server.client.request("GET", "/\(token)/js/lib/native.js")
    #expect(response.status == 200)
    #expect(response.headers["content-type"] == "text/javascript")
    #expect(response.text == nativeJS)
    #expect(response.headers["content-security-policy"] == "frame-ancestors 'none'")
    let head = try await server.client.request("HEAD", "/\(token)/js/lib/native.js")
    #expect(head.status == 200)
    #expect(head.headers["content-length"] == String(nativeJS.utf8.count))
    #expect(head.body.isEmpty)
}

@Test func unknownTypesAreServedAsOctetStream() async throws {
    let server = try TestServer()
    defer { server.stop() }
    try Data([0, 1]).write(to: server.html.appendingPathComponent("liveset.tsl"))
    let response = try await server.client.request("GET", "/\(token)/liveset.tsl")
    #expect(response.headers["content-type"] == "application/octet-stream")
    #expect(response.body == Data([0, 1]))
}

@Test func foldersAndMissingFilesAreNotFound() async throws {
    let server = try TestServer()
    defer { server.stop() }
    for path in ["/\(token)/js", "/\(token)/js/", "/\(token)/js/lib/missing.js", "/\(token)/%252e%252e/x"] {
        #expect(try await server.client.status("GET", path) == 404, "\(path)")
    }
}

@Test func traversalOutOfTheWebAppIsRefused() async throws {
    let server = try TestServer()
    defer { server.stop() }
    let outside = server.html.deletingLastPathComponent()
    try "secret".write(to: outside.appendingPathComponent("secret"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
        at: server.html.appendingPathComponent("link"), withDestinationURL: outside.appendingPathComponent("secret"))
    for path in [
        "/\(token)/../secret", "/\(token)/%2e%2e/secret", "/\(token)/js/../../secret", "/\(token)/js/%2E%2E/../secret",
        "/\(token)/..%2fsecret", "/\(token)/link", "/\(token)/\(outside.path)/secret", "/\(token)/../html/../secret",
    ] {
        let response = try await server.client.request("GET", path)
        #expect(response.status == 403 || response.status == 404, "\(path)")
        #expect(response.text != "secret", "\(path)")
    }
}

@Test func aNULCannotCutThePathShort() async throws {
    let server = try TestServer()
    defer { server.stop() }
    for path in ["/\(token)/index.html%00.png", "/\(token)/js/lib/native.js%00", "/\(token)/%00"] {
        #expect(try await server.client.status("GET", path) == 404, "\(path)")
    }
}

@Test func noSpellingOfTheIndexSkipsTheOriginCheck() async throws {
    let server = try TestServer()
    defer { server.stop() }
    for path in [
        "/\(token)", "/\(token)/", "/\(token)/./", "/\(token)/./index.html", "/\(token)/%69ndex.html",
        "/\(token)/index.html?x", "/\(token)//index.html", "/\(token)/js/../index.html", "/%74est-token/index.html",
    ] {
        #expect(
            try await server.client.status("GET", path, headers: [("Sec-Fetch-Site", "cross-site")]) == 403,
            "\(path)")
        #expect(try await server.client.request("GET", path).text.contains("var base = '/\(token)/';"), "\(path)")
    }
}

@Test func indexHooksNativeJSWithTheTokenAndCannotBeFramed() async throws {
    let server = try TestServer()
    defer { server.stop() }
    let response = try await server.client.request(
        "GET", "/\(token)/index.html", headers: [("Sec-Fetch-Site", "none")])
    #expect(response.status == 200)
    #expect(response.headers["content-type"] == "text/html; charset=utf-8")
    let page = response.text
    let base = try #require(page.range(of: "var base = '/\(token)/';"))
    let tag = try #require(page.range(of: PageScript.nativeScriptTag))
    #expect(base.lowerBound < tag.lowerBound)
    #expect(page.contains(#"["app_storage2","midi_send"].forEach"#))
    #expect(response.headers["x-frame-options"] == "DENY")
    #expect(response.headers["content-security-policy"]?.contains("frame-ancestors 'none'") == true)
}

@Test func thePageCarriesTheFullCSP() async throws {
    let server = try TestServer()
    defer { server.stop() }
    var nonces: [String] = []
    for _ in 0..<2 {
        let response = try await server.client.request("GET", "/\(token)/index.html")
        let policy = try #require(response.headers["content-security-policy"])
        let nonce = try #require(response.text.firstMatch(of: /<script nonce="([^"]+)">/)).output.1
        #expect(policy == PageScript.contentSecurityPolicy(nonce: String(nonce)))
        #expect(policy.contains("'nonce-\(nonce)'"))
        nonces.append(String(nonce))
    }
    #expect(nonces[0] != nonces[1])  // a fresh nonce for every response
    let head = try await server.client.request("HEAD", "/\(token)/index.html")
    #expect(head.headers["content-security-policy"]?.contains("'nonce-") == true)
    #expect(head.body.isEmpty)
}

@Test func unsupportedIndexExplainsItself() async throws {
    let server = try TestServer()
    defer { server.stop() }
    try "<html></html>".write(to: server.html.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    let response = try await server.client.request("GET", "/\(token)/index.html")
    #expect(response.status == 500)
    #expect(response.text.contains("not supported"))
    #expect(server.log.all == ["[bts] index.html no longer loads js/lib/native.js; unsupported app version"])
}

// MARK: the server

@Test func theServerListensOn127001Only() async throws {
    let server = try TestServer()
    defer { server.stop() }
    #expect(!canConnectToIPv6Loopback(port: server.port))
}

private func canConnectToIPv6Loopback(port: UInt16) -> Bool {
    let socket = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
    defer { Darwin.close(socket) }
    var address = sockaddr_in6()
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    address.sin6_family = sa_family_t(AF_INET6)
    address.sin6_port = port.bigEndian
    address.sin6_addr = in6addr_loopback
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
        }
    }
}

@Test func keepAliveServesSeveralRequestsOnOneConnection() async throws {
    let server = try TestServer()
    defer { server.stop() }
    let host = [("Host", server.client.host)]
    let page = RawHTTPClient.bytes("GET", "/\(token)/index.html", headers: host, body: nil)
    let script = RawHTTPClient.bytes("HEAD", "/\(token)/js/lib/native.js", headers: host, body: nil)
    let command = RawHTTPClient.bytes(
        "POST", "/\(token)/$$app_storage2", headers: host + [("Content-Type", "application/json")],
        body: Data(#"["k"]"#.utf8))
    let last = RawHTTPClient.bytes(
        "GET", "/\(token)/js/lib/native.js", headers: host + [("Connection", "close")], body: nil)
    let (statuses, closeHeader, closed) = try await offThePool {
        let connection = try RawHTTPConnection(port: server.port)
        var statuses: [Int] = []
        try connection.send(page)
        statuses.append(try connection.readResponse().status)
        try connection.send(script)
        statuses.append(try connection.readResponse(toHead: true).status)
        try connection.send(command + command)  // pipelined: both answered, in order
        statuses.append(try connection.readResponse().status)
        statuses.append(try connection.readResponse().status)
        try connection.send(last)
        let response = try connection.readResponse()
        statuses.append(response.status)
        return (statuses, response.headers["connection"], try connection.isClosedByServer())
    }
    #expect(statuses == [200, 200, 200, 200, 200])
    #expect(closeHeader == "close")
    #expect(closed)
    #expect(server.dispatcher.calls.count == 2)
}

@Test func aSlowRequestDoesNotBlockOtherConnections() async throws {
    // The slow fetch answers only once the fast request has been answered: a server that took one connection at a
    // time would leave the fast one waiting, and the client's 5 s receive timeout would fail the test.
    let (gate, open) = AsyncStream.makeStream(of: Never.self)
    defer { open.finish() }
    let proxy = StubProxy { _ in
        for await _ in gate {}  // until the gate opens
        return .response(status: 200, contentType: "application/json", body: Data("{}".utf8))
    }
    let server = try TestServer(proxy: proxy)
    defer { server.stop() }
    async let slow = server.client.request("GET", "/\(token)/proxy?url=x")
    for _ in 0..<200 where proxy.urls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    try #require(!proxy.urls.isEmpty)
    let response = try await server.client.command("/\(token)/$$app_storage2", ["k"])
    #expect(response.status == 200)
    open.finish()
    #expect(try await slow.status == 200)
}
