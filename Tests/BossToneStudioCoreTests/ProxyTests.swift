import Foundation
import Testing

@testable import BossToneStudioCore

private let plain = "text/plain; charset=utf-8"

// MARK: checkedURL

@Test func toneCentralHostsAreFetchedOverHttps() throws {
    #expect(try Proxy.checkedURL("http://api.roland.com/x?y=1").absoluteString == "https://api.roland.com/x?y=1")
    #expect(
        try Proxy.checkedURL("http://api.roland.com/app/btc/define/katana_mk2.json").absoluteString
            == "https://api.roland.com/app/btc/define/katana_mk2.json")
    #expect(
        try Proxy.checkedURL("https://bosstonecentral.com/a.tsl").absoluteString == "https://bosstonecentral.com/a.tsl")
    #expect(
        try Proxy.checkedURL("https://www.youtube.com/iframe_api").absoluteString
            == "https://www.youtube.com/iframe_api")
}

@Test func theAllowlistIsExactlyToneCentralsHosts() {
    #expect(Proxy.allowedHosts == ["api.roland.com", "bosstonecentral.com", "www.youtube.com"])
}

@Test func schemeAndHostMatchInAnyCase() throws {
    #expect(try Proxy.checkedURL("HTTP://API.Roland.COM/x").absoluteString == "https://api.roland.com/x")
    #expect(try Proxy.checkedURL("HtTpS://BossToneCentral.com/x").absoluteString == "https://bosstonecentral.com/x")
}

@Test func everythingElseIsRefused() {
    for url in [
        "ftp://api.roland.com/", "https://example.com/", "https://api.roland.com.evil.com/",
        "https://api.roland.com.evil.com", "https://evil.com#api.roland.com", "https://evil.com/?api.roland.com",
        "https://api.roland.com@evil.example/", "https://api.roland.com:pw@evil.example/",
        "https://evil.example%2f@api.roland.com.evil.example/", "https://api.roland.com%2eevil.example/",
        "https://w.soundcloud.com/player/api.js", "https://api.soundcloud.com/x", "https://dev-api.roland.com/x",
        "https://api.roland.com./x", "https://evilbosstonecentral.com/", "https://sub.bosstonecentral.com/",
        "file:///etc/hosts", "javascript:alert(1)", "data:text/plain,hi", "//api.roland.com/x", "/x",
        "api.roland.com/x",
        "", " ",
    ] {
        #expect(throws: MessageError.self, "\(url) must be refused") { try Proxy.checkedURL(url) }
    }
}

@Test func urlsAreRebuiltWithoutUserinfoOrPort() throws {
    #expect(
        try Proxy.checkedURL("https://u:p@bosstonecentral.com:8443/a.tsl#f").absoluteString
            == "https://bosstonecentral.com/a.tsl")
    #expect(try Proxy.checkedURL("http://api.roland.com:8080/x?y=1#z").absoluteString == "https://api.roland.com/x?y=1")
    #expect(try Proxy.checkedURL("https://api.roland.com").absoluteString == "https://api.roland.com")
}

@Test func theRebuiltURLNamesTheAllowlistedHostAndNothingElse() throws {
    for url in [
        "https://u:p@bosstonecentral.com:8443/a.tsl#f", "https://bosstonecentral.com/@evil.example/x",
        "https://bosstonecentral.com?@evil.example", "https://bosstonecentral.com/../../x?a=b@evil.example",
    ] {
        let checked = try Proxy.checkedURL(url)
        #expect(checked.scheme == "https")
        #expect(checked.host == "bosstonecentral.com", "\(url)")
        #expect(checked.user == nil && checked.password == nil && checked.port == nil && checked.fragment == nil)
    }
}

@Test func aBackslashBeforeTheHostIsUserinfoNotAHost() throws {
    // Browsers read `\` as `/` and would go to evil.example; the URL is rebuilt from the allowlisted host either way,
    // so the request cannot leave it.
    let checked = try Proxy.checkedURL("https://evil.example\\@api.roland.com/x")
    #expect(checked.absoluteString == "https://api.roland.com/x")
}

@Test func percentEncodingOfPathAndQueryIsKept() throws {
    #expect(
        try Proxy.checkedURL("https://bosstonecentral.com/my%20set/a%2Fb.tsl?name=a%26b&x=%E2%82%AC").absoluteString
            == "https://bosstonecentral.com/my%20set/a%2Fb.tsl?name=a%26b&x=%E2%82%AC")
}

@Test func charactersThePageLeftUnencodedAreEncoded() throws {
    #expect(
        try Proxy.checkedURL("https://bosstonecentral.com/my set/é.tsl?q=a b").absoluteString
            == "https://bosstonecentral.com/my%20set/%C3%A9.tsl?q=a%20b")
}

// MARK: the request

@Test func aFetchIsAGetWithThe20sTimeoutAndTheUserAgent() throws {
    let request = Proxy.request(for: try Proxy.checkedURL("https://api.roland.com/x"))
    #expect(request.url?.absoluteString == "https://api.roland.com/x")
    #expect(request.httpMethod == "GET")
    #expect(request.timeoutInterval == 20)
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "Mozilla/5.0 (Macintosh)")
    #expect(Proxy().session.configuration.timeoutIntervalForRequest == 20)
}

@Test func theSessionSendsNoCookiesAndGivesUpAfter60s() {
    // As 0.1.1's urllib: no cookies either way. A server trickling bytes cannot hold a connection forever.
    let configuration = Proxy().session.configuration
    #expect(configuration.httpShouldSetCookies == false)
    #expect(configuration.httpCookieAcceptPolicy == .never)
    #expect(configuration.httpCookieStorage == nil)
    #expect(configuration.timeoutIntervalForResource == 60)
}

// MARK: redirects

private let someResponse = HTTPURLResponse(
    url: URL(string: "https://api.roland.com/")!, statusCode: 302, httpVersion: nil, headerFields: nil)!

/// Plays URLSession's part without a network: the task is created but never resumed.
private func follow(_ redirects: AllowlistedRedirects, to target: String) async -> URLRequest? {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: URL(string: "https://api.roland.com/")!)
    return await redirects.urlSession(
        session, task: task, willPerformHTTPRedirection: someResponse, newRequest: URLRequest(url: URL(string: target)!)
    )
}

@Test func aRedirectOutsideTheAllowlistIsStoppedAndRemembered() async {
    for target in [
        "https://evil.example/", "ftp://api.roland.com/", "https://api.roland.com.evil.example/",
        "https://w.soundcloud.com/player/api.js",
    ] {
        let redirects = AllowlistedRedirects()
        #expect(await follow(redirects, to: target) == nil, "\(target)")
        #expect(redirects.refusal?.contains("redirect") == true, "\(target)")
    }
}

@Test func aRedirectWithinTheAllowlistIsFollowedToTheRebuiltURL() async throws {
    let redirects = AllowlistedRedirects()
    let next = try #require(await follow(redirects, to: "http://u:p@www.youtube.com:8080/embed/x?a=1#f"))
    #expect(next.url?.absoluteString == "https://www.youtube.com/embed/x?a=1")
    #expect(next.value(forHTTPHeaderField: "User-Agent") == "Mozilla/5.0 (Macintosh)")
    #expect(redirects.refusal == nil)
}

// MARK: gate

private func response(_ result: ProxyResult) -> (status: Int, contentType: String, body: Data)? {
    guard case .response(let status, let contentType, let body) = result else { return nil }
    return (status, contentType, body)
}

@Test func rolandBodiesMustBeJSON() {
    for host in ["api.roland.com", "bosstonecentral.com"] {
        let html = Data("<script>alert(1)</script>".utf8)
        for body in [html, Data("{\"unterminated\":".utf8), Data(), Data("alert(1)".utf8)] {
            guard case .failed(let message) = Proxy.gate(host: host, status: 200, contentType: "text/html", body: body)
            else {
                Issue.record("\(host) \(String(decoding: body, as: UTF8.self)) must fail")
                continue
            }
            #expect(message.contains(host) && message.hasSuffix("is not JSON"))
        }
    }
}

@Test func jsonFragmentsAreJSON() {
    for body in ["\"text\"", "42", "null", "true", "[]", "{\"a\":[1,2]}", " \n{\"a\":1}\n"] {
        let result = Proxy.gate(host: "api.roland.com", status: 200, contentType: "text/plain", body: Data(body.utf8))
        #expect(response(result)?.body == Data(body.utf8), "\(body)")
    }
}

@Test func tslKeepsAPlainTextType() {
    let result = Proxy.gate(
        host: "bosstonecentral.com", status: 200, contentType: "binary/octet-stream", body: Data("{}".utf8))
    #expect(result == .response(status: 200, contentType: plain, body: Data("{}".utf8)))
}

@Test func jsonStaysJSON() {
    for type in ["application/json; charset=utf-8", "application/json", "Application/JSON", "application/vnd.api+json"]
    {
        let result = Proxy.gate(host: "api.roland.com", status: 200, contentType: type, body: Data("{}".utf8))
        #expect(result == .response(status: 200, contentType: "application/json", body: Data("{}".utf8)), "\(type)")
    }
}

@Test func aMissingOrOtherTypeBecomesPlainText() {
    for type in ["text/html", "text/javascript", "application/octet-stream", ""] {
        let result = Proxy.gate(host: "api.roland.com", status: 200, contentType: type, body: Data("{}".utf8))
        #expect(response(result)?.contentType == plain, "\(type)")
    }
}

@Test func rolandErrorsKeepStatusButNoBody() {
    for status in [301, 304, 400, 404, 500, 503] {
        for host in ["api.roland.com", "bosstonecentral.com"] {
            let html = Data("<script>alert(1)</script>".utf8)
            #expect(
                Proxy.gate(host: host, status: status, contentType: "text/html", body: html)
                    == .response(status: status, contentType: plain, body: Data()))
            #expect(
                Proxy.gate(host: host, status: status, contentType: "application/json", body: Data("{}".utf8))
                    == .response(status: status, contentType: plain, body: Data()))
        }
    }
}

@Test func youtubePassesUnchanged() {
    let js = Data("var YT = {};".utf8)
    #expect(
        Proxy.gate(host: "www.youtube.com", status: 200, contentType: "text/javascript", body: js)
            == .response(status: 200, contentType: "text/javascript", body: js))
    #expect(
        Proxy.gate(host: "www.youtube.com", status: 404, contentType: "text/html", body: js)
            == .response(status: 404, contentType: "text/html", body: js))
}

@Test func aHostOutsideTheListIsHeldToJSONToo() {
    // Unreachable through fetch; gate fails closed rather than passing an unknown host's bytes unchanged.
    let js = Data("var x;".utf8)
    #expect(
        Proxy.gate(host: "example.com", status: 200, contentType: "text/javascript", body: js)
            == .failed("example.com response is not JSON"))
}

// MARK: fetch (no network: refusals are decided before any request)

@Test func fetchRefusesWithoutTouchingTheNetwork() async {
    let result = await Proxy().fetch("https://evil.example/\n[js] forged")
    guard case .refused(let message) = result else {
        Issue.record("expected .refused, got \(result)")
        return
    }
    #expect(message.contains("'https://evil.example/\\n[js] forged'"))  // page-chosen text goes through escaped()
    #expect(!message.contains("\n"))
}
