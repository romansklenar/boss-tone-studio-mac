# ADR-0003: Lock the bridge to this page and these files

Status: accepted, 2026-10-27 (from a security review)

## Context

The bridge reads and writes files and opens URLs. Any web page open in the user's browser could otherwise call it on
`localhost`, and DNS rebinding could reach it under another host name.

## Decision

Listen on loopback only; check `Host` on every request; require a per-launch secret token as a path prefix (held by the
injected script, [ADR-0010](ADR-0010-native-js-app-hook-as-the-transport.md)); reject foreign `Origin`/`Sec-Fetch-Site`
and forbid framing, so no other website can open the editor either; limit file access to the app's folders and paths
picked in a file dialog; let `fs.exec` open `http(s)` links only. The rules are listed in `doc/bridge-protocol.md`.

## Consequences

- Other websites cannot drive the bridge; tests cover the token and request handling.
- Until 0.2.0, any local program that is not a browser — including other user accounts and sandboxed apps — could read
  the token from `index.html`. It then reached the amp, the Librarian, the files picked this session, file dialogs and
  web links, but nothing else. Since 0.2.0 the server answers nothing without the token, so it no longer gives it
  away; the window opens the page with it. Code running in the page still has the bridge's reach (see Residual risks).

## Known weak points

From a security review on 2026-10-28; none was exploitable without code already on the Mac or in the page. The native
app fixed each of them in 0.2.0 ([ADR-0011](ADR-0011-native-swift-app.md)); the rules are in `doc/bridge-protocol.md`.

| Weak point | Fixed in 0.2.0 |
|---|---|
| The token is served to any local client (above) | The page and its files live under `/<token>/` too, and the window opens `/<token>/index.html`; any path without the token is `403` |
| Proxied scripts (YouTube, SoundCloud, Roland) and Tone Central titles, which the page renders as HTML, run with the token | `index.html` comes with a Content-Security-Policy whose per-response nonce admits the bridge script, so inline scripts, injected event handlers and `javascript:` URLs are blocked; SoundCloud left the allowlist; Roland's hosts must answer with JSON, passed on as `application/json` or `text/plain` |
| CoreMIDI port names are rendered as HTML, and any process can name a virtual port | Ports whose names contain `<>&"'` are neither listed nor opened |
| pywebview opens `target=_blank` links of any scheme in the browser | The web view opens no windows: a clicked `http(s)` link goes to the default browser, other schemes are dropped, and `window.open` without a click does nothing; the window stays on `http://127.0.0.1:P`, and subframes load `https` only |
| A file picked to open may also be written | Separate sets: a file picked to open is read only, a path picked to save is writable |
| If `::1` cannot be bound for a reason other than "in use" (e.g. IPv6 off), the server runs on IPv4 only and a local squatter could serve its own page there | The server binds `127.0.0.1` only and accepts only `Host: 127.0.0.1:P`; `localhost` and `[::1]` are refused |
| `make app` bundles `build/roland/html` without re-checking it against the verified zip | `make app` extracts the web app again from the SHA-256-checked zip on every build |
| The proxy keeps userinfo and any port from the requested URL (still only allowlisted hosts over HTTPS) | The URL, and every redirect, is rebuilt from `https`, the host name, path and query |
| The bundle is only ad-hoc signed (PyInstaller's default), without the hardened runtime | Signed with `--options runtime`; `make install` checks the signature and the runtime flag before copying |

## Residual risks

- jQuery evaluates any `<script>` in HTML it inserts, and `'unsafe-eval'`, which Roland's knob and spinner controls
  need, lets that run. A `<script>` in Tone Central's content, which the page renders as HTML, would run with the
  bridge's reach. Roland's hosts are held to JSON, but JSON can carry such a string. A WebKit check confirmed it: under
  the policy, a `<script>` inserted with `.html()` and `eval` both ran, while an inline script, an injected handler
  and a `javascript:` URL were blocked.
- YouTube's player API (`iframe_api`) passes the proxy unchanged and is evaluated in the page, and the player's scripts
  load from `https://www.youtube.com`. The preview player therefore trusts YouTube with the bridge's reach.
- Any script in the page can call the bridge's methods; the token only keeps everything outside the page out.
