import Foundation
import Testing

@testable import BossToneStudioCore

@Test func everySpellingOfThisMacIsThisMac() {
    let local = [
        "", ".", "127.0.0.1", "127.0.0.1.", "127.1", "127.255.255.254", "0x7f000001", "2130706433", "0177.0.0.1",
        "0.0.0.0", "0", "localhost", "LOCALHOST.", "app.localhost", "::1", "::", "::ffff:127.0.0.1", "::127.0.0.1",
    ]
    for host in local { #expect(isThisMac(host: host), "\(host)") }
    for host in ["example.com", "127.example.com", "192.168.1.1", "10.0.0.1", "2001:db8::1", "::ffff:192.168.1.1"] {
        #expect(!isThisMac(host: host), "\(host)")
    }
}

@Test func onlyWebLinksOffThisMacMayReachTheBrowser() throws {
    // As WebKit hands them to the window, and as the page hands them to `fs_exec`.
    let allowed = [
        "https://www.roland.com/support/", "http://example.com/a?b=c", "HTTPS://Example.com/", "Http://[2001:db8::1]/",
    ]
    for link in allowed { #expect(isWebLinkOffThisMac(try #require(URL(string: link))), "\(link)") }
    let refused = [
        "http://127.0.0.1:8080/token/index.html", "HTTP://127.0.0.1:8080/token/", "http://127.1:8080/token/",
        "http://0x7f000001:8080/", "http://localhost:8080/", "http://[::1]:8080/", "http://%31%32%37.0.0.1/",
        "http:///127.0.0.1/", "http:example.com", "http://user@example.com/", "http://:secret@example.com/",
        "mailto:a@example.com", "about:blank", "file:///etc/hosts", "ftp://example.com/", "javascript:alert(1)",
    ]
    for link in refused { #expect(!isWebLinkOffThisMac(try #require(URL(string: link))), "\(link)") }
}
