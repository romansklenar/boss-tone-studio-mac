# Design: a native Swift app instead of the Python shell

Date: 2026-10-28. Status: approved for planning. Branch `feat/native-app`, released as 0.2.0.

## Why

The 0.1.x app works, but it is a 38 MB bundle carrying its own Python, and building it needs mise, uv, a pinned
Python, python-rtmidi compiled from source and PyInstaller. [ADR-0001](../decisions/ADR-0001-python-shell-around-rolands-web-app.md)
kept a native shell (WKWebView + embedded HTTP server + CoreMIDI) as the later step. This is that step: the same app
for the user, with a much smaller bundle and a build that needs only the Swift toolchain from Apple's Command Line
Tools. No Xcode, no third-party packages.

## Goals

- A Swift app that does everything 0.1.1 does, for Roland's unchanged MkII web app 2.1.0: the window, the bridge, MIDI,
  storage, file dialogs, Tone Central, the Librarian import, the close handshake.
- Every accepted ADR stays in force, except where it names Python technology. `doc/bridge-protocol.md` stays the
  specification, updated only where this design deliberately changes a rule (see Security).
- The weak points listed in ADR-0003 ("Known weak points") are fixed in this rewrite, not later.
- Users carry on seamlessly: same app name, bundle identifier, icon, data folder and on-disk formats, so the Librarian,
  the stored MIDI device and settings work unchanged.
- The Python code, its tests and its tooling are removed in the same branch once the native app passes the amp test
  below.

## Non-goals

- App Sandbox, notarisation, a Developer ID signature, distribution of the built app (licensing: README).
- Intel builds; macOS older than 14.
- Pushed events (`startevent`); real CoreMIDI unique IDs (ADR-0005 stays, see below); KATANA Gen 3.
- Any change to Roland's files, or to what the page sees beyond the documented injection.

## Anti-goals (failure even if it "works")

- Losing or rewriting the user's Librarian, or any format change that 0.1.1 could not read back.
- Leaving the amp in editor mode after closing the app.
- Reaching any network host outside the proxy allowlist, or exposing the token to anything but the page.
- A Roland file in git, or the built `.app` attached anywhere.
- Regressions against the 0.1.1 checks in `doc/testing.md`.

## Constraints

- Toolchain: Command Line Tools only (currently Swift 6.4, macOS 27 SDK). They include Swift Testing (`import Testing`)
  and `swift format`, but no XCTest and no Xcode. CI's macOS runner uses Xcode's Swift, so the package must build with
  the Swift version that runner ships (`swift-tools-version` no newer than that).
- Deployment target macOS 14 (`platforms: [.macOS(.v14)]`, `LSMinimumSystemVersion` 14.0), arm64 only.
- No package dependencies: Foundation, AppKit, WebKit, Network, CoreMIDI, UniformTypeIdentifiers only.
- Signing: ad-hoc (`codesign --sign -`) with the hardened runtime; no Developer ID exists.
- Claude Code's sandbox cannot create a CoreMIDI client, and `swift`/`xcrun` need their cache outside it. Logic must be
  testable without CoreMIDI (MIDI behind a protocol), and builds that need it run outside the sandbox.
- Repo rules (AGENTS.md): English in code and docs, Conventional Commits, 120-character lines, lean comments, decisions
  as ADRs, nothing of Roland's committed.

## Decided

### Shape of the code

A Swift package at the repository root (`Package.swift`, `Sources/`, `Tests/`), next to `bts/` until Python is removed.
A library target holds everything testable without a window or a MIDI client (HTTP server and routing, bridge command
table, storage, file permissions, proxy, MIDI message handling, Librarian import, data-folder lock). An executable
target holds the AppKit window, WebKit delegates, file dialogs, the CoreMIDI backend and the command line. Swift 6
language mode.

### HTTP server

- Network.framework `NWListener` on `127.0.0.1` only, port chosen by the system. A small HTTP/1.1 implementation:
  request line, headers, `Content-Length` bodies (no chunked request bodies: `400`), keep-alive, GET/HEAD/POST
  (`501` otherwise). The page polls every 50 ms with synchronous XHR, so keep-alive matters.
- Static files from Roland's web app folder, content type by extension (UniformTypeIdentifiers), confined to that
  folder after resolving the path.
- Requests are answered off the main thread. Synchronous XHR blocks only WebKit's web content process, so the app's
  main thread stays free for file dialogs and window work.

### Bridge

Same command table, behaviour, event queue (cap 10,000), JSON answers, `500` with the error message, injected script
and close handshake as 0.1.1 (`doc/bridge-protocol.md`). Same storage layout in the data folder: `storage.json`,
`storage2/<key>` with the key percent-encoded exactly as Python's `urllib.parse.quote(key, safe="")` does (ASCII
letters, digits and `-._~` stay; everything else is `%XX` of its UTF-8 bytes; `''`, `.`, `..` refused), atomic writes
(temporary file + rename), `roland-librarian-imported` marker, `app.lock` (`flock`, one process per data folder, which
also keeps the Python and Swift apps off the same folder at once). Temp folder `bts-*`, removed on exit.

### MIDI

- CoreMIDI directly. Port names must equal what python-rtmidi reported (`KATANA`, `KATANA DAW CTRL` on the verified
  amps), because the page stored `KATANA` as the device's `MIDIEndpointUIDKey` (ADR-0005 stays: the name is the UID).
  Verify against the 0.1.1 list with an amp; if the display name differs, reproduce rtmidi's naming.
- Incoming: one event per whole message, SysEx reassembled across packets, timing clock (`F8`) and active sensing
  (`FE`) dropped, hex uppercase, timestamp in milliseconds since the epoch.
- Outgoing: hex → bytes → whole messages (same splitting rules as `bts/midi.py`) → CoreMIDI.
- Hot-plug: CoreMIDI's setup-changed notification instead of polling; emit `midi\fchanged` only when the port lists
  really changed.

### Window

- AppKit, no nib: one window titled `BOSS TONE STUDIO for KATANA MkII (Apple Silicon)`, 1280×800, minimum 1160×700, a
  WKWebView on the default website data store.
- Standard app menu (Quit) and Edit menu (copy/paste/select all in text fields need it). Cmd-Q and the close button
  both go through the close handshake (`app\fcommand\fexit`, 2 s fallback, closes refused until `$$app_exit`); closing
  the window quits the app.
- `alert()`/`confirm()`/`prompt()` shown as native panels: Roland's page uses `alert()`.
- File dialogs: `NSOpenPanel`/`NSSavePanel` on the main thread, answered asynchronously through `fs` events as now.
- Web Inspector enabled only with `BTS_TRACE=1`.

### Command line, environment, logging

`--browser` (serve only, print the URL), `--import-roland` (import and exit, refused while the folder is locked),
`BTS_DATA_DIR`, `BTS_HTML_DIR`, `BTS_TRACE=1`. Log lines keep their prefixes and shapes (`[bts]`, `[trace] -> $$…`,
`[trace] <- midi.message …`, `[js] …`), so the trace checklist in `doc/testing.md` still applies. Web app lookup order
as now: `BTS_HTML_DIR`, the bundle's `roland-html`, the checkout's `build/roland/html`, Roland's installed app.

### Security: 0.1.1's rules plus the ADR-0003 follow-ups

All rules in `doc/bridge-protocol.md` › Security stay (Host check, token with constant-time compare, origin and
`Sec-Fetch-Site`, POST-only JSON commands, `$$<object>_<method>` names, argument shape, body cap, framing forbidden,
telemetry `204`, file allowlist, `fs_exec` http(s) only, redacted and escaped logs). The weak points are fixed as
follows:

1. **Token no longer served to any local client.** Everything, the page and its static files included, lives under
   `/<token>/` (`/<token>/index.html`, `/<token>/js/…`); any path without the token is `403`/`404`. Roland's page loads
   its files by relative URL, so it works unchanged. The window and `--browser` open
   `http://127.0.0.1:<port>/<token>/index.html`.
2. **IPv4 only.** Bind `127.0.0.1` only; trusted `Host` is `127.0.0.1:<port>`, the page's origin is
   `http://127.0.0.1:<port>`. `localhost` and `[::1]` are refused.
3. **MIDI port names with markup skipped**: names containing any of `<>&"'` are not listed.
4. **External links**: the web view never opens new windows; `target=_blank` and `window.open` for `http(s)` go to
   the default browser, other schemes are dropped. Top-level navigation stays on the page's origin. Subframes (the
   YouTube player) may load `https` only.
5. **CSP, proxy narrowed.**
   - `index.html` gets a `Content-Security-Policy` with a per-launch nonce on the injected script. Roland's code needs
     `'unsafe-eval'` (knob and spinner controls use `eval`; jQuery 1.12 evaluates the proxied YouTube API with it).
     YouTube's widget script and player need `https://www.youtube.com` in `script-src`/`frame-src`.
   - Roland's one inline handler (`<body oncontextmenu="return false">`) must keep working: allow it by hash
     (`'unsafe-hashes'`) if WebKit honours that, otherwise suppress the context menu natively.
   - The policy blocks injected event handlers and `javascript:` URLs, but not `<script>` in HTML that jQuery inserts
     (it evaluates those, and `'unsafe-eval'` allows that). Record this residual risk in ADR-0003.
   - SoundCloud leaves the allowlist (its previews never worked).
   - Responses from Roland's hosts (`api.roland.com`, `bosstonecentral.com`) pass only if they parse as JSON
     (`502` otherwise). They go out as `application/json` when Roland's server said JSON, else as `text/plain`, so
     jQuery never treats them as script or HTML. Relabelling everything as JSON would break Tone Central: `.tsl` files
     come as `binary/octet-stream`, and the page fetches them without a `dataType` and calls `JSON.parse` on the
     string itself. Verify with the catalogue, a liveset's details and adding a liveset.
6. **Separate read and write sets.** Data and temp folders: read and write. A file picked in the open dialog: read
   only. A path picked in the save dialog: write (and read).
7. **Proxy URLs rebuilt** from scheme `https`, the host name, path and query only; userinfo, port and fragment are
   dropped. Redirects are held to the allowlist. GET only, POST still dropped with `204`. 20 s timeout, same User-Agent.
8. **`make app` re-extracts** Roland's web app from the verified zip into the bundle on every build, instead of
   trusting `build/roland/html`.
9. **Hardened runtime**: `codesign --force --sign - --options runtime`; `make install` verifies the signature
   (`codesign --verify --strict`) and the runtime flag. No entitlements unless one proves necessary.

ADR-0003's table is updated to mark each as fixed, with the residual risks that remain.

### Build, version, CI

- `make` stays the entry point: `setup` (check the toolchain, `roland-assets`), `run`, `browser`, `trace`,
  `roland-import`, `app`, `install`, `test` (`swift test`), `lint`/`format` (`swift format` with a `.swift-format`
  config at 120 columns), `check`. `make app` builds release arm64, assembles `Contents/MacOS`, `Info.plist`
  (identifier `local.boss-tone-studio-mac.katana-mk2`, version), `Resources/roland-html` and `AppIcon.icns`, then signs.
- The icon is recoloured as now (Roland's dark background `#242424` → slate grey `#5C6370`, tolerance 48, partial
  shift on anti-aliased edges), by a small Swift tool or script instead of Pillow.
- The version moves to a `VERSION` file at the root (AGENTS.md updated); 0.2.0.
- CI: one macOS job running `make lint` and `make test`; actions stay pinned to commit SHAs. mise, uv and the Ubuntu
  lint job go.
- New ADRs: the native app (supersedes ADR-0001 and the PyInstaller part of ADR-0008) and the Swift-only toolchain
  (supersedes ADR-0009). ADR-0005's context gets a note that the name stays the UID for the stored choice.

### Tests

- Swift Testing in `Tests/`. Port every Python test (the security rules against a real loopback server with a
  stand-in bridge, files, storage, close handshake, command names, no `startevent`, proxy allowlist, MIDI splitting,
  connect failure with a fake MIDI backend, Librarian import with plist fixtures, the lock), plus one per fixed weak
  point.
- The page side, which unit tests never run: run Roland's real `native.js` against the injected script in Node with a
  stub XHR, as for 0.1.1, before the amp test.
- `--browser` in a browser at `http://127.0.0.1:<port>/<token>/index.html` (Claude's browser pane or Chrome): the page
  loads, `DEVICE NOT FOUND`, offline mode, Tone Central catalogue, details and YouTube preview. `--browser` gets no
  exception from the 127.0.0.1-only rule; if no automated browser reaches it, these checks move to the app window
  during the amp session. AGENTS.md's sandbox note changes from `localhost` to `127.0.0.1`.

### Done when

1. `make check` passes locally and in CI.
2. With the built `.app` (`BTS_TRACE=1`, a copy of the data folder), on the KATANA-ARTIST MkII and the KATANA-HEAD
   MkII, Roman confirms everything in `doc/testing.md` › With an amp: Identity Reply, connect, editor mode on, both
   directions, `.tsl` export and import, All Data Backup and its restore, deleting a patch and a liveset, clean close
   with editor mode off. Plus: alerts appear, Tone Central works, the window opens with the existing Librarian.
3. The bundle is a few MB plus Roland's 13 MB web app, signed with the hardened runtime.
4. Python, its tests, `mise.toml`, `pyproject.toml`, `requirements*.txt`, `packaging/app.spec` and
   `packaging/make_icon.py` are removed; README, AGENTS.md, `doc/` and CHANGELOG (0.2.0) describe the Swift app.

The native app installs over 0.1.x under the same name. The fallback is the `v0.1.1` tag (`make setup app install` on
it).

## Left to the builder

- File and type names within the two targets; whether the bridge is an actor or a lock-guarded class.
- Which CoreMIDI API generation to use (legacy packet lists or MIDI 1.0 event lists), as long as SysEx reassembly and
  the port names are right.
- The HTTP parser's internals, MIME table details, how the icon tool is run.
- Order of work, as long as Python stays runnable until the amp test passes.
