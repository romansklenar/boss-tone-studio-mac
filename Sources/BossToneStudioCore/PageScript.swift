import CryptoKit
import Foundation

/// What the bridge adds to Roland's `index.html`, and the policy the page is served under.
public enum PageScript {
    /// Roland's tag that loads `native.js`; the script goes right before it, so it runs first (jQuery is loaded).
    public static let nativeScriptTag = #"<script src="js/lib/native.js"></script>"#

    /// `native.js` checks for `window.$$app` before anything else and then calls `window['$$' + object][method](args)`
    /// for every command, using the result as is. This script defines those methods, one per bridge command, each
    /// forwarding the call behind a per-launch token. The bridge has no `app_startevent`, so `native.js` keeps polling
    /// `$$app.getevent`; the script serves that from a local queue it refills with one `$$app_getevents` request
    /// (ADR-0014). Otherwise it is 0.1.1's script with the nonce on its opening tag.
    ///
    /// `token` must be URL-safe (`makeToken()`): it goes into a JS string and a URL path unescaped.
    public static func preNative(token: String, nonce: String, commands: [String]) -> String {
        let commandsJSON = jsonArray(commands)
        return #"""
            <script nonce="\#(nonce)">
            (function () {
              var base = '/\#(token)/';
              function call(command, args) {
                var x = new XMLHttpRequest();
                x.open('POST', base + command, false);
                x.setRequestHeader('Content-Type', 'application/json');
                x.send(JSON.stringify(args.map(String)));  // String(): what native.js's own URL transport would send
                if (x.status !== 200) throw new Error(x.status === 500 ? x.responseText : 'bridge answered HTTP ' + x.status);
                var value = JSON.parse(x.responseText);
                return value === null ? undefined : value;
              }
              \#(commandsJSON).forEach(function (command) {
                var split = command.indexOf('_'), object = '$$' + command.slice(0, split);
                (window[object] = window[object] || {})[command.slice(split + 1)] = function () {
                  return call('$$' + command, Array.prototype.slice.call(arguments));
                };
              });
              var pending = [], next = 0;
              window.$$app.getevent = function () {
                if (next >= pending.length) {
                  pending = JSON.parse(call('$$app_getevents', []));
                  next = 0;
                }
                return next < pending.length ? pending[next++] : undefined;
              };
              window.addEventListener('error', function (e) {
                var x = new XMLHttpRequest();
                x.open('POST', base + 'log', true);
                x.send(e.message + ' @ ' + e.filename + ':' + e.lineno);
              });
              // Tone Central's servers send no CORS headers, so its absolute URLs go through the local proxy.
              $.ajaxPrefilter(function (options) {
                if (/^https?:\/\//.test(options.url)) {
                  options.url = base + 'proxy?url=' + encodeURIComponent(options.url);
                  options.crossDomain = false;
                }
              });
            })();
            </script>

            """#
    }

    /// `html` with the script before the first `native.js` tag; nil when the tag is missing, an app version this
    /// bridge does not know (the page would load without the bridge, so the caller shows `unsupportedPage`).
    public static func inject(into html: String, token: String, nonce: String, commands: [String]) -> String? {
        guard let tag = html.range(of: nativeScriptTag) else { return nil }
        var injected = html
        injected.insert(contentsOf: preNative(token: token, nonce: nonce, commands: commands), at: tag.lowerBound)
        return injected
    }

    /// Roland's page runs `eval` (knob and spinner controls, jQuery's script evaluation), so `'unsafe-eval'` stays;
    /// the one inline handler, `<body oncontextmenu="return false">`, is allowed by hash and every other inline script
    /// by nonce. YouTube's widget needs its own host in `script-src` and `frame-src`.
    public static func contentSecurityPolicy(nonce: String) -> String {
        [
            "default-src 'self'",
            "script-src 'self' 'nonce-\(nonce)' 'unsafe-eval' 'unsafe-hashes' 'sha256-\(handlerHash)' "
                + "https://www.youtube.com",
            "style-src 'self' 'unsafe-inline'",
            "img-src 'self' https: data:",
            "frame-src https://www.youtube.com",
            "connect-src 'self'",
            "font-src 'self' data:",
            "object-src 'none'",
            "base-uri 'self'",
            "form-action 'none'",
            "frame-ancestors 'none'",
        ].joined(separator: "; ")
    }

    /// What 0.1.1 answered when `index.html` has no `native.js` to hook, in the same words.
    public static let unsupportedPage = """
        <!doctype html><meta charset="utf-8"><title>Unsupported</title>
        <p>This version of Roland's editor is not supported: its <code>index.html</code> no longer loads
        <code>js/lib/native.js</code>. Rebuild with <code>make roland-assets</code>.</p>
        """

    /// A CSP hash covers the text of the attribute: Roland's `oncontextmenu="return false"`.
    private static let handlerHash = Data(SHA256.hash(data: Data("return false".utf8))).base64EncodedString()

    /// `<` is escaped so no command name can close the script block.
    private static func jsonArray(_ items: [String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = (try? encoder.encode(items)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
    }
}
