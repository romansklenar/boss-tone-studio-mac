import CryptoKit
import Foundation
import Testing

@testable import BossToneStudioCore

private let tag = PageScript.nativeScriptTag
private let commands = ["app_getevent", "midi_send"]

private func page(around middle: String = tag) -> String {
    "<!doctype html>\n<body oncontextmenu=\"return false\">\n<script src=\"js/lib/jquery.js\"></script>\n\(middle)\n</body>"
}

// MARK: injection

@Test func injectionHooksNativeJsWithTokenNonceAndCommands() throws {
    let html = page()
    let injected = try #require(
        PageScript.inject(into: html, token: "T0ken_-x", nonce: "N+once/==", commands: commands))
    #expect(injected.contains("<script nonce=\"N+once/==\">"))
    #expect(injected.contains("var base = '/T0ken_-x/';"))
    #expect(injected.contains(#"["app_getevent","midi_send"].forEach(function (command) {"#))
    let script = try #require(injected.range(of: "<script nonce="))
    let native = try #require(injected.range(of: tag))
    #expect(script.lowerBound < native.lowerBound)
    #expect(injected.contains("</script>\n" + tag))  // the block sits directly before Roland's tag
    // Nothing else of Roland's page changes.
    let block = PageScript.preNative(token: "T0ken_-x", nonce: "N+once/==", commands: commands)
    #expect(injected.replacingOccurrences(of: block, with: "") == html)
}

@Test func theInjectedScriptServesGetEventFromALocalQueue() {
    let script = PageScript.preNative(token: "T", nonce: "N", commands: commands)
    #expect(script.contains("window.$$app.getevent = function () {"))
    #expect(script.contains("if (next >= pending.length) {"))
    #expect(script.contains("pending = JSON.parse(call('$$app_getevents', []));"))
    #expect(script.contains("return next < pending.length ? pending[next++] : undefined;"))
    #expect(!script.contains("shift()"))  // O(n) per event on a batch of up to 10,000
    let forEach = script.range(of: ".forEach(function (command) {")
    let override = script.range(of: "window.$$app.getevent = ")
    #expect(forEach != nil && override != nil && forEach!.lowerBound < override!.lowerBound)
}

@Test func injectionRefusesAPageWithoutNativeJs() {
    #expect(PageScript.inject(into: "<html></html>", token: "T", nonce: "N", commands: commands) == nil)
    #expect(PageScript.inject(into: "", token: "T", nonce: "N", commands: commands) == nil)
    let changed = page(around: #"<script src="js/lib/native.js?v=2"></script>"#)
    #expect(PageScript.inject(into: changed, token: "T", nonce: "N", commands: commands) == nil)
}

@Test func theScriptIsInjectedBeforeTheFirstTagOnly() throws {
    let injected = try #require(
        PageScript.inject(
            into: page(around: tag + "\n<!-- " + tag + " -->"), token: "T", nonce: "N", commands: commands))
    #expect(injected.components(separatedBy: "<script nonce=").count == 2)
}

@Test func theScriptIsRolandsTemplateWithOnlyTheOpeningTagChanged() {
    let script = PageScript.preNative(token: "TOK", nonce: "NON", commands: ["a_b"])
    #expect(
        script.hasPrefix(
            "<script nonce=\"NON\">\n(function () {\n  var base = '/TOK/';\n  function call(command, args) {\n"))
    #expect(script.hasSuffix("})();\n</script>\n"))
    #expect(script.contains("  [\"a_b\"].forEach(function (command) {\n"))
    // Escaping and comments as in 0.1.1's script.
    #expect(script.contains(#"    if (/^https?:\/\//.test(options.url)) {"#))
    #expect(
        script.contains(
            "    x.send(JSON.stringify(args.map(String)));  // String(): what native.js's own URL transport would send\n"
        ))
    #expect(
        script.contains(
            "  // Tone Central's servers send no CORS headers, so its absolute URLs go through the local proxy.\n"))
    #expect(script.contains("x.open('POST', base + command, false);"))
    #expect(script.contains("x.open('POST', base + 'log', true);"))
    #expect(script.contains("options.url = base + 'proxy?url=' + encodeURIComponent(options.url);"))
    #expect(script.contains("return call('$$' + command, Array.prototype.slice.call(arguments));"))
    #expect(script.contains("object = '$$' + command.slice(0, split);"))
    #expect(!script.contains("%("))
}

@Test func commandNamesCannotCloseTheScriptBlock() {
    let script = PageScript.preNative(token: "T", nonce: "N", commands: ["a_</script><b>", "c_d/e"])
    #expect(!script.contains("</script><b>"))
    #expect(script.contains(#"["a_\u003c/script>\u003cb>","c_d/e"]"#))
}

// MARK: policy

@Test func cspAllowsOnlyTheNonceAndRolandsHandler() {
    let policy = PageScript.contentSecurityPolicy(nonce: "N+once/==")
    let hash = Data(SHA256.hash(data: Data("return false".utf8))).base64EncodedString()
    #expect(policy.contains("'nonce-N+once/=='"))
    #expect(policy.contains("'unsafe-eval'"))
    #expect(policy.contains("'unsafe-hashes'"))
    #expect(policy.contains("'sha256-\(hash)'"))
    #expect(policy.contains("frame-ancestors 'none'"))
    let scriptSource = policy.components(separatedBy: "; ").first { $0.hasPrefix("script-src ") }
    #expect(scriptSource?.contains("'unsafe-inline'") == false)
}

@Test func cspIsTheSpecifiedPolicy() {
    let hash = Data(SHA256.hash(data: Data("return false".utf8))).base64EncodedString()
    #expect(
        PageScript.contentSecurityPolicy(nonce: "NON")
            == "default-src 'self'; script-src 'self' 'nonce-NON' 'unsafe-eval' 'unsafe-hashes' 'sha256-\(hash)' "
            + "https://www.youtube.com; style-src 'self' 'unsafe-inline'; img-src 'self' https: data:; "
            + "frame-src https://www.youtube.com; connect-src 'self'; font-src 'self' data:; object-src 'none'; "
            + "base-uri 'self'; form-action 'none'; frame-ancestors 'none'")
}

@Test func theHandlerHashIsTheKnownDigestOfReturnFalse() {
    // `printf 'return false' | openssl dgst -sha256 -binary | base64`: a second source besides CryptoKit.
    #expect(
        PageScript.contentSecurityPolicy(nonce: "N").contains(" 'sha256-GZIcz60Uwd6wT3vaYke/atSr53TehbYAPepOa3d03Vw=' ")
    )
}

// MARK: unsupported page

@Test func theUnsupportedPageSaysWhatToDo() {
    let text = PageScript.unsupportedPage
    #expect(text.hasPrefix("<!doctype html><meta charset=\"utf-8\"><title>Unsupported</title>\n<p>"))
    #expect(text.contains("<code>js/lib/native.js</code>"))
    #expect(text.contains("<code>make roland-assets</code>"))
    #expect(text.hasSuffix("</p>"))
}
