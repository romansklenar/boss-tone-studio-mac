import Foundation
import Testing

@testable import BossToneStudioCore

private func data(_ text: String) -> Data { Data(text.utf8) }

private func post(_ body: String, headers: String = "") -> String {
    "POST /T/$$app_storage HTTP/1.1\r\nHost: 127.0.0.1:1\r\nContent-Length: \(body.utf8.count)\r\n\(headers)\r\n\(body)"
}

/// The request and how many bytes it used; nil unless `text` holds exactly one complete valid request prefix.
private func parsed(_ text: String) -> (request: HTTPRequest, consumed: Int)? {
    guard case .request(let request, let consumed) = parseRequest(data(text)) else { return nil }
    return (request, consumed)
}

private func isInvalid(_ text: String, maxHeaderBytes: Int = 65_536, maxBodyBytes: Int = 67_108_864) -> Bool {
    guard
        case .invalid(let status) = parseRequest(data(text), maxHeaderBytes: maxHeaderBytes, maxBodyBytes: maxBodyBytes)
    else { return false }
    return status == 400
}

private func wire(_ response: HTTPResponse, keepAlive: Bool = true, includeBody: Bool = true) -> String {
    String(decoding: response.serialized(keepAlive: keepAlive, includeBody: includeBody), as: UTF8.self)
}

// MARK: parsing

@Test func aCompleteRequestIsParsed() throws {
    let text = post("hello", headers: "Content-Type: application/json\r\n")
    let (request, consumed) = try #require(parsed(text))
    #expect(request.method == "POST")
    #expect(request.target == "/T/$$app_storage")
    #expect(request.version == "HTTP/1.1")
    #expect(String(decoding: request.body, as: UTF8.self) == "hello")
    #expect(consumed == text.utf8.count)
    #expect(request.header("content-type") == "application/json")
    #expect(request.header("CONTENT-LENGTH") == "5")
    #expect(request.header("X-Missing") == nil)
    #expect(request.requestLine == "POST /T/$$app_storage HTTP/1.1")
}

@Test func headerValuesLoseOptionalWhitespaceAndTheFirstOfRepeatedHeadersWins() throws {
    let (request, _) = try #require(
        parsed("GET / HTTP/1.1\r\nHost:   127.0.0.1:1 \t\r\nX-A: first\r\nx-a: second\r\n\r\n"))
    #expect(request.header("host") == "127.0.0.1:1")
    #expect(request.header("X-A") == "first")
    #expect(request.headers.count == 3)
}

@Test func pathAndQueryAreSplitAtTheFirstQuestionMark() throws {
    let (withQuery, _) = try #require(parsed("GET /T/proxy?url=a%3Fb?c HTTP/1.1\r\n\r\n"))
    #expect(withQuery.path == "/T/proxy")
    #expect(withQuery.query == "url=a%3Fb?c")
    let (plain, _) = try #require(parsed("GET /a%2fb HTTP/1.1\r\n\r\n"))
    #expect(plain.path == "/a%2fb")  // raw: decoding is the router's job
    #expect(plain.query == "")
}

@Test func connectionsStayAliveUnlessOneSideSaysOtherwise() throws {
    func keepAlive(_ head: String) throws -> Bool {
        try #require(parsed(head + "\r\n")).request.keepAlive
    }
    #expect(try keepAlive("GET / HTTP/1.1\r\n"))
    #expect(try !keepAlive("GET / HTTP/1.0\r\n"))
    #expect(try !keepAlive("GET / HTTP/1.1\r\nConnection: close\r\n"))
    #expect(try !keepAlive("GET / HTTP/1.1\r\nConnection: Keep-Alive, CLOSE\r\n"))
    #expect(try keepAlive("GET / HTTP/1.1\r\nConnection: keep-alive\r\n"))
}

private func isIncomplete(_ text: String) -> Bool {
    guard case .incomplete = parseRequest(data(text)) else { return false }
    return true
}

@Test func partialRequestsWaitForTheRest() {
    let text = post("hello")
    #expect(isIncomplete(""))
    #expect(isIncomplete("GET / HT"))  // cut mid-line
    #expect(isIncomplete("GET / HTTP/1.1\r\nHost: x\r\n\r"))  // cut inside the terminator
    #expect(isIncomplete(String(text.dropLast(5))))  // head complete, no body byte yet
    #expect(isIncomplete(String(text.dropLast())))  // body short by one byte
}

@Test func theRequestIsReadOnceItsLastByteArrives() throws {
    let text = post("hello")
    for cut in 0..<text.utf8.count {
        let result = parseRequest(Data(text.utf8.prefix(cut)))
        guard case .incomplete = result else {
            Issue.record("\(cut) of \(text.utf8.count) bytes must be incomplete, got \(result)")
            return
        }
    }
    #expect(try #require(parsed(text)).consumed == text.utf8.count)
}

@Test func pipelinedRequestsAreParsedOneByOne() throws {
    let first = "GET /one HTTP/1.1\r\nHost: x\r\n\r\n"
    let second = post("second")
    let buffer = data(first + second)
    guard case .request(let one, let consumed) = parseRequest(buffer) else {
        Issue.record("the first request must parse")
        return
    }
    #expect(one.target == "/one")
    #expect(consumed == first.utf8.count)
    guard case .request(let two, let rest) = parseRequest(buffer.dropFirst(consumed)) else {
        Issue.record("the second request must parse from the rest, a slice that does not start at zero")
        return
    }
    #expect(two.method == "POST")
    #expect(String(decoding: two.body, as: UTF8.self) == "second")
    #expect(rest == second.utf8.count)
}

@Test func theBodyEndsWhereContentLengthSaysEvenWhenMoreBytesFollow() throws {
    let (request, consumed) = try #require(parsed(post("abc") + "GET"))
    #expect(String(decoding: request.body, as: UTF8.self) == "abc")
    #expect(consumed == post("abc").utf8.count)
}

@Test func bodiesMayHoldAnyBytes() {
    var buffer = data("POST /x HTTP/1.1\r\nContent-Length: 6\r\n\r\n")
    buffer.append(contentsOf: [0, 13, 10, 13, 10, 255])
    guard case .request(let request, let consumed) = parseRequest(buffer) else {
        Issue.record("a body containing CRLFCRLF must not confuse the head")
        return
    }
    #expect(Array(request.body) == [0, 13, 10, 13, 10, 255])
    #expect(consumed == buffer.count)
}

@Test func badLengthsAndChunkedBodiesAreRefused() {
    for length in [
        "-1", "+5", "1e3", " 5", "5 5", "0x10", "", "five", "5,5", "١٢", "\t5", String(67_108_864 + 1),
        "99999999999999999999999999",
    ] {
        // The first space is the one after the colon; whatever follows is the value.
        #expect(isInvalid("POST / HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n"), "\(length.debugDescription)")
    }
    #expect(isInvalid("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"))
    #expect(isInvalid("POST / HTTP/1.1\r\ntransfer-encoding: identity\r\nContent-Length: 0\r\n\r\n"))
    #expect(isInvalid("POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello!"))
}

@Test func theBodyLimitIsInclusiveAndDecidedFromTheHeaderAlone() throws {
    #expect(!isInvalid("POST / HTTP/1.1\r\nContent-Length: 4\r\n\r\n", maxBodyBytes: 4))
    #expect(isInvalid("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\n", maxBodyBytes: 4))  // no body bytes needed
    let limit = 64 * 1024 * 1024
    #expect(isInvalid("POST / HTTP/1.1\r\nContent-Length: \(limit + 1)\r\n\r\n"))
    guard case .incomplete = parseRequest(data("POST / HTTP/1.1\r\nContent-Length: \(limit)\r\n\r\n")) else {
        Issue.record("a body of exactly 64 MiB is allowed, so its request waits for the body")
        return
    }
}

@Test func repeatedEqualLengthsAreOneLength() throws {
    let (request, consumed) = try #require(
        parsed("POST / HTTP/1.1\r\nContent-Length: 2\r\ncontent-length: 2\r\n\r\nhi"))
    #expect(request.body == data("hi"))
    #expect(consumed == "POST / HTTP/1.1\r\nContent-Length: 2\r\ncontent-length: 2\r\n\r\nhi".utf8.count)
}

@Test func aRequestWithoutContentLengthHasNoBody() throws {
    let (request, consumed) = try #require(parsed("POST /x HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\n\r\n"))
    #expect(request.body.isEmpty)
    #expect(consumed == "POST /x HTTP/1.1\r\nHost: x\r\n\r\n".utf8.count)
}

@Test func oversizedHeadersAreRefused() {
    let filler = String(repeating: "X-Filler: " + String(repeating: "a", count: 90) + "\r\n", count: 700)
    #expect(filler.utf8.count > 65_536)
    #expect(isInvalid("GET / HTTP/1.1\r\n" + filler))  // 70 KB, no CRLFCRLF yet
    #expect(isInvalid("GET / HTTP/1.1\r\n" + filler + "\r\n"))  // terminated, but past the limit
    #expect(isInvalid(String(repeating: "a", count: 70_000)))
    #expect(isInvalid("GET / HTTP/1.1\r\nHost: a\r\n\r\n", maxHeaderBytes: 20))
    #expect(!isInvalid("GET / HTTP/1.1\r\nHost: a\r\n\r\n", maxHeaderBytes: 27))  // exactly the head's length
}

@Test func aBodyDoesNotCountAgainstTheHeaderLimit() {
    let text = post(String(repeating: "x", count: 5_000))
    guard case .request = parseRequest(data(text), maxHeaderBytes: 200) else {
        Issue.record("only the head is limited by maxHeaderBytes")
        return
    }
}

@Test func malformedRequestLinesAreRefused() {
    for line in [
        "", "GET", "GET /", "GET / ", "GET  / HTTP/1.1", " GET / HTTP/1.1", "GET / HTTP/1.1 ", "GET / HTTP/1.1 x",
        "GET / HTTP/2.0", "GET / HTTP/1", "GET / HTTP/1.10", "GET / HTTP/1.x", "GET / http/1.1", "GET / HTTP/0.9",
        "G\u{01}T / HTTP/1.1", "GET /a\u{7f}b HTTP/1.1", "GE:T / HTTP/1.1", "GET\t/ HTTP/1.1", "/ HTTP/1.1",
        "GET /caf\u{E9} HTTP/1.1",  // raw bytes from 0x80 up (RFC 9112); XHR percent-encodes them
    ] {
        #expect(isInvalid(line + "\r\n\r\n"), "\(line.debugDescription)")
    }
}

@Test func malformedHeadersAreRefused() {
    for header in [
        "NoColon", ": empty-name", "Bad Name: x", "Bad-Name : x", " Folded: x", "\tFolded: x", "X: a\0b", "X: a\nb",
        "X: a\rb",
    ] {
        #expect(isInvalid("GET / HTTP/1.1\r\n\(header)\r\n\r\n"), "\(header.debugDescription)")
    }
    // Line feeds without a carriage return end no line: the head never ends.
    guard case .incomplete = parseRequest(data("GET / HTTP/1.1\nHost: x\n\n")) else {
        Issue.record("a head with bare line feeds must not parse")
        return
    }
}

@Test func headerBytesAreReadAsLatin1SoNothingFailsToDecode() throws {
    var buffer = data("GET /caf%C3%A9 HTTP/1.1\r\nX-Name: ")
    buffer.append(0xFF)
    buffer.append(data("\r\n\r\n"))
    guard case .request(let request, _) = parseRequest(buffer) else {
        Issue.record("non-ASCII header bytes must parse")
        return
    }
    #expect(request.target == "/caf%C3%A9")
    #expect(request.header("x-name") == "\u{FF}")
}

@Test func aSecondHostOriginFetchSiteOrContentTypeIsRefused() {
    // The router reads one of each; something in between could read the other.
    for name in ["Host", "Origin", "Sec-Fetch-Site", "Content-Type"] {
        #expect(isInvalid("GET / HTTP/1.1\r\n\(name): a\r\n\(name): a\r\n\r\n"), "\(name)")
        #expect(isInvalid("GET / HTTP/1.1\r\n\(name): a\r\nX-Other: b\r\n\(name.lowercased()): c\r\n\r\n"), "\(name)")
        #expect(parsed("GET / HTTP/1.1\r\n\(name): a\r\n\r\n") != nil, "\(name)")
    }
}

// MARK: responses

@Test func everyResponseForbidsFramingAndCaching() {
    let responses = [
        HTTPResponse.text("hi"), .error(404), HTTPResponse(status: 200, contentType: "text/html", body: data("<p>")),
        HTTPResponse(status: 204),
    ]
    for response in responses {
        for keepAlive in [true, false] {
            let text = wire(response, keepAlive: keepAlive)
            #expect(text.contains("\r\nCache-Control: no-store\r\n"))
            #expect(text.contains("\r\nX-Frame-Options: DENY\r\n"))
            #expect(text.contains("\r\nX-Content-Type-Options: nosniff\r\n"))
            #expect(text.contains("\r\nContent-Security-Policy: frame-ancestors 'none'\r\n"))
        }
    }
    let ok = wire(.text("hi"))
    #expect(ok.hasPrefix("HTTP/1.1 200 OK\r\n"))
    #expect(ok.contains("\r\nContent-Length: 2\r\n"))
    #expect(ok.contains("\r\nContent-Type: text/plain; charset=utf-8\r\n"))
    #expect(ok.hasSuffix("\r\n\r\nhi"))
}

@Test func aResponseCanSetItsOwnContentSecurityPolicyButNothingElseOfTheSet() {
    let own = HTTPResponse(
        status: 200, contentType: "text/html", body: data("x"),
        headers: [("content-security-policy", "default-src 'self'")])
    let text = wire(own)
    #expect(text.contains("\r\ncontent-security-policy: default-src 'self'\r\n"))
    #expect(!text.contains("frame-ancestors"))
    #expect(text.contains("\r\nX-Frame-Options: DENY\r\n"))
}

@Test func connectionCloseIsAnnouncedOnlyWhenTheConnectionWillClose() {
    #expect(wire(.text("x"), keepAlive: false).contains("\r\nConnection: close\r\n"))
    #expect(!wire(.text("x"), keepAlive: true).contains("Connection"))
}

@Test func headResponsesHaveNoBody() {
    let response = HTTPResponse(status: 200, contentType: "text/html", body: data("<p>hello</p>"))
    let head = wire(response, includeBody: false)
    #expect(head.hasSuffix("\r\n\r\n"))
    #expect(!head.contains("<p>"))
    #expect(head.contains("\r\nContent-Length: 12\r\n"))  // what GET would send
    #expect(wire(response).hasSuffix("\r\n\r\n<p>hello</p>"))
}

@Test func statusesWithoutABodyHaveNoContentLength() {
    for status in [204, 304] {
        let text = wire(HTTPResponse(status: status, body: data("ignored")))
        #expect(!text.contains("Content-Length"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }
    #expect(wire(HTTPResponse(status: 204)).hasPrefix("HTTP/1.1 204 No Content\r\n"))
}

@Test func errorsAnswerTheirStatusAndReasonAsPlainText() {
    for (status, reason) in [
        (400, "Bad Request"), (403, "Forbidden"), (404, "Not Found"), (405, "Method Not Allowed"),
        (415, "Unsupported Media Type"), (500, "Internal Server Error"), (502, "Bad Gateway"),
    ] {
        let response = HTTPResponse.error(status)
        #expect(response.status == status)
        #expect(response.contentType == "text/plain; charset=utf-8")
        #expect(String(decoding: response.body, as: UTF8.self) == "\(status) \(reason)")
        #expect(wire(response).hasPrefix("HTTP/1.1 \(status) \(reason)\r\n"))
    }
}

@Test func textIsUtf8() {
    let response = HTTPResponse.text("h\u{E9}", status: 500)
    #expect(response.status == 500)
    #expect(Array(response.body) == [0x68, 0xC3, 0xA9])
    #expect(wire(response).contains("\r\nContent-Length: 3\r\n"))
}

@Test func theResponseOwnsItsFraming() {
    let response = HTTPResponse(
        status: 200, contentType: "text/plain", body: data("abc"),
        headers: [("Content-Length", "999"), ("transfer-encoding", "chunked"), ("Connection", "upgrade"), ("X-A", "1")])
    let text = wire(response)
    #expect(text.components(separatedBy: "Content-Length").count == 2)
    #expect(text.contains("\r\nContent-Length: 3\r\n"))
    #expect(!text.lowercased().contains("transfer-encoding"))
    #expect(!text.contains("upgrade"))
    #expect(text.contains("\r\nX-A: 1\r\n"))
}

@Test func headerTextCannotSplitTheResponse() {
    let response = HTTPResponse(
        status: 200, contentType: "text/plain\r\nSet-Cookie: a=b", body: Data(),
        headers: [("X-A", "1\r\nX-B: 2"), ("X-C\r\n", "3\nx"), ("X-D", "4\r\n\r\nbody")])
    let text = wire(response)
    let head = text.components(separatedBy: "\r\n\r\n")[0]
    #expect(head.components(separatedBy: "\r\n").allSatisfy { !$0.hasPrefix("Set-Cookie") && !$0.hasPrefix("X-B") })
    #expect(text.components(separatedBy: "\r\n\r\n").count == 2)  // exactly one head/body separator
    #expect(!text.contains("\nx"))
}

// MARK: tokens and nonces

@Test func tokensAreLongAndUnique() {
    let tokens = (0..<20).map { _ in makeToken() }
    for token in tokens {
        #expect(token.utf8.count == 32)
        #expect(token.utf8.allSatisfy(isURLSafe), "\(token)")
    }
    #expect(Set(tokens).count == tokens.count)
}

private func isURLSafe(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
        UInt8(ascii: "0")...UInt8(ascii: "9"),
        UInt8(ascii: "_"), UInt8(ascii: "-"):
        true
    default:
        false
    }
}

@Test func noncesAreSixteenBytesOfBase64() throws {
    let nonces = (0..<20).map { _ in makeNonce() }
    for nonce in nonces {
        #expect(try #require(Data(base64Encoded: nonce)).count == 16)
        #expect(nonce.utf8.count == 24)
    }
    #expect(Set(nonces).count == nonces.count)
}

@Test func tokenComparisonSeesEveryDifference() {
    #expect(constantTimeEquals("abc", "abc"))
    #expect(constantTimeEquals("", ""))
    #expect(!constantTimeEquals("abc", "abd"))
    #expect(!constantTimeEquals("abc", "ab"))
    #expect(!constantTimeEquals("ab", "abc"))
    #expect(!constantTimeEquals("abc", "abc\0"))
    #expect(!constantTimeEquals("", "a"))
    #expect(constantTimeEquals("t\u{F6}ken", "t\u{F6}ken"))  // non-ASCII compares as bytes
    #expect(!constantTimeEquals("t\u{F6}ken", "token"))
}
