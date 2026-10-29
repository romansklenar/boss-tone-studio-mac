# Design: a native Swift app instead of the Python shell

Date: 2026-10-28. Status: implemented in 0.2.0. The decisions are recorded in
[ADR-0011](../decisions/ADR-0011-native-swift-app.md) and
[ADR-0012](../decisions/ADR-0012-swift-toolchain-without-dependencies.md), the protocol and security rules in
[`doc/bridge-protocol.md`](../bridge-protocol.md).

## Why

The 0.1.x app worked, but it was a 38 MB bundle carrying its own Python, and building it needed mise, uv, a pinned
Python, python-rtmidi compiled from source and PyInstaller.
[ADR-0001](../decisions/ADR-0001-python-shell-around-rolands-web-app.md) kept a native shell (WKWebView + embedded
HTTP server + CoreMIDI) as the later step. This is that step: the same app for the user, with a much smaller bundle and
a build that needs only the Swift toolchain from Apple's Command Line Tools. No Xcode, no third-party packages.

## Goals

- A Swift app that does everything 0.1.1 does, for Roland's unchanged MkII web app 2.1.0: the window, the bridge, MIDI,
  storage, file dialogs, Tone Central, the Librarian import, the close handshake.
- Every accepted ADR stays in force, except where it names Python technology. `doc/bridge-protocol.md` stays the
  specification, changed only where this design deliberately changes a rule (see Security).
- The weak points listed in ADR-0003 are addressed in this rewrite, not later; what remains is recorded there as
  residual risks.
- Users carry on seamlessly: same app name, bundle identifier, icon, data folder and on-disk formats, so the Librarian,
  the stored MIDI device and settings work unchanged.
- Every Python test gets a Swift Testing counterpart; the Python code, its tooling and its tests go in the same release,
  once the native app has passed the amp test.

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

- Toolchain: the Command Line Tools only (Swift 6.4 and the macOS 27 SDK at the time). They include Swift Testing and
  `swift format`, but no XCTest and no Xcode. CI's macOS runner uses Xcode's Swift, so `swift-tools-version` stays no
  newer than the Swift that runner ships.
- Swift is pinned to major version 6 only; an exact pin through mise was tried and dropped (ADR-0012).
- Deployment target macOS 14 (`platforms: [.macOS(.v14)]`, `LSMinimumSystemVersion` 14.0), arm64 only.
- No package dependencies: Apple's frameworks only (ADR-0012 lists them).
- Signing: ad-hoc (`codesign --sign -`) with the hardened runtime; no Developer ID exists.
- Claude Code's sandbox cannot create a CoreMIDI client, and `swift`/`xcrun` need their cache outside it. Logic must be
  testable without CoreMIDI (MIDI behind a protocol), and builds that need it run outside the sandbox.
- Repo rules (AGENTS.md): English in code and docs, Conventional Commits, 120-character lines, lean comments, decisions
  as ADRs, nothing of Roland's committed.

## Decided

### Shape of the code

A Swift package at the repository root (`Package.swift`, `Sources/`, `Tests/`), Swift 6 language mode. The library
`BossToneStudioCore` holds everything testable without a window or a MIDI client: HTTP server and routing, bridge
command table, storage, file permissions, proxy, MIDI message handling and packet conversion, Librarian import,
data-folder lock. The executable `BossToneStudio` holds the AppKit window, WebKit delegates, file dialogs, the CoreMIDI
backend and the command line. The tests are the target `BossToneStudioCoreTests`.

### HTTP server

- Network.framework `NWListener` on `127.0.0.1` only, port chosen by the system. A small hand-written HTTP/1.1 server:
  GET/HEAD/POST (`501` otherwise), `Content-Length` bodies only, keep-alive (the page polls every 50 ms with
  synchronous XHR), and strict parsing: anything that could be read two ways is refused. A connection is closed after
  30 s without a complete request.
- Static files from Roland's web app folder, the MIME type from `UTType(filenameExtension:)`, confined to that folder
  after resolving the path.
- Requests are answered off the main thread. Synchronous XHR blocks only WebKit's web content process, so the app's
  main thread stays free for file dialogs and window work.

### Bridge

Same command table, behaviour, event queue (cap 10,000), JSON answers, `500` with the error message, injected script
and close handshake as 0.1.1 (`doc/bridge-protocol.md`). Commands answer synchronously, like the page's synchronous
XHR, so the bridge is a `final class` with its mutable state behind `OSAllocatedUnfairLock` (`Mutex` needs macOS 15)
rather than an actor, and window work hops to the main thread.

Same storage layout in the data folder: `storage.json`, `storage2/<key>` with the key percent-encoded exactly as
Python's `urllib.parse.quote(key, safe="")` did, atomic writes, the `roland-librarian-imported` marker, and `app.lock`
(`flock`, one process per data folder; 0.1.x took the same lock, so the two apps never share a folder at once). Text
is returned as stored, where 0.1.1 turned CR and CRLF into LF. A temp folder `bts-*`, removed on exit.

### MIDI

- CoreMIDI directly, through the current API: `MIDIInputPortCreateWithProtocol(._1_0)` and `MIDISendEventList` with
  Universal MIDI Packets. Converting between MIDI 1.0 bytes and packets is a pure function in the library, unit-tested
  without a MIDI client; warnings as errors keep deprecated calls out.
- Port names equal what python-rtmidi reported (`KATANA`, `KATANA DAW CTRL` on the verified amps), because the page
  stored `KATANA` as the device's `MIDIEndpointUIDKey` (ADR-0005: the name is the UID). They are built as rtmidi's
  `CreateEndpointName`; ports with connections drawn in Audio MIDI Setup are the only ones python-rtmidi named
  otherwise (ADR-0011). Both amps reconnected to the stored device without the device picker.
- Incoming: one event per whole message, SysEx reassembled across packets, timing clock (`F8`) and active sensing
  (`FE`) dropped, hex uppercase, timestamp in milliseconds since the epoch.
- Outgoing: hex → bytes → whole messages (0.1.1's splitting rules) → packets → CoreMIDI.
- Hot-plug: CoreMIDI's setup-changed notification instead of 0.1.x's 1.5 s poll; `midi\fchanged` only when the port
  lists really changed.

### Window

- AppKit, no nib: one window titled `BOSS TONE STUDIO for KATANA MkII (Apple Silicon)`, 1280×800, minimum 1160×700, a
  WKWebView on the default website data store.
- Standard app menu (Quit) and Edit menu (copy/paste/select all in text fields need it). Cmd-Q, the close button and
  `SIGINT`/`SIGTERM` all go through the close handshake (`app\fcommand\fexit`, 2 s fallback, closes refused until
  `$$app_exit`); closing the window quits the app.
- `alert()`/`confirm()`/`prompt()` shown as native sheets: Roland's page uses `alert()`.
- File dialogs: `NSOpenPanel`/`NSSavePanel` sheets on the main thread, answered asynchronously through `fs` events; the
  name the page suggests only fills the save panel's name field.
- No context menu: Roland's own inline handler is allowed by the policy (Security, 5), and the web view drops its menu
  items as well.
- Web Inspector enabled only with `BTS_TRACE=1`.

### Command line, environment, logging

`--browser` (serve only, print the URL), `--import-roland` (import and exit, refused while the folder is locked),
`BTS_DATA_DIR`, `BTS_HTML_DIR`, `BTS_TRACE=1`. Log lines keep their prefixes and shapes (`[bts]`, `[trace] -> $$…`,
`[trace] <- midi.message …`, `[js] …`), so the trace checklist in `doc/testing.md` still applies. The web app comes from
`BTS_HTML_DIR` as given when it is set, else from the first of the bundle's `roland-html` (inside a `.app` only), the
checkout's `build/roland/html` and Roland's installed app that has an `index.html`.

### Security: 0.1.1's rules plus the ADR-0003 follow-ups

All rules in `doc/bridge-protocol.md` › Security stay (Host check, token with constant-time compare, origin and
`Sec-Fetch-Site`, POST-only JSON commands, `$$<object>_<method>` names, argument shape, body cap, framing forbidden,
telemetry `204`, file allowlist, `fs_exec` for web links only, redacted and escaped logs). The weak points are
addressed as follows; the rules themselves are in that document:

1. **Token no longer served to any local client.** Everything, the page and its static files included, lives under
   `/<token>/`; any path without the token is `403`. Roland's page loads its files by relative URL, so it works
   unchanged. The window and `--browser` open `http://127.0.0.1:<port>/<token>/index.html`.
2. **IPv4 only.** Bind `127.0.0.1` only; the trusted `Host` is `127.0.0.1:<port>`, the page's origin
   `http://127.0.0.1:<port>`. `localhost` and `[::1]` are refused.
3. **MIDI port names with markup skipped**: names containing any of `<>&"'` are neither listed nor opened.
4. **External links**: the web view opens no new windows. A clicked `http(s)` link goes to the default browser, other
   schemes are dropped, and `window.open` without a user gesture does nothing. Top-level navigation stays on the page's
   origin; subframes (the YouTube player) load only `https` or stay blank. `fs_exec` refuses links back to this Mac,
   whose URLs would hand the browser the token.
5. **CSP, proxy narrowed.**
   - `index.html` gets a `Content-Security-Policy` with a nonce, new for every response, on the injected script.
     Roland's code needs `'unsafe-eval'` (knob and spinner controls use `eval`; jQuery 1.12 evaluates the proxied
     YouTube API with it), and YouTube's widget script and player need `https://www.youtube.com`.
   - Roland's one inline handler (`<body oncontextmenu="return false">`) is allowed by hash with `'unsafe-hashes'`,
     which WebKit honours.
   - The policy blocks injected event handlers and `javascript:` URLs, but not `<script>` in HTML that jQuery inserts
     (it evaluates those, and `'unsafe-eval'` allows that): a residual risk, recorded in ADR-0003.
   - SoundCloud left the allowlist (its previews never worked).
   - Responses from Roland's hosts (`api.roland.com`, `bosstonecentral.com`) pass only if they parse as JSON (`502`
     otherwise). They go out as `application/json` when Roland's server said JSON, else as `text/plain`, so jQuery
     never treats them as script or HTML. Relabelling everything as JSON would break Tone Central: `.tsl` files come as
     `binary/octet-stream`, and the page parses the string itself. Every response also carries
     `X-Content-Type-Options: nosniff`.
6. **Separate read and write sets.** Data and temp folders: read and write. A file picked in the open dialog: read
   only. A path picked in the save dialog: write (and read). A path that does not exist yet resolves through its
   nearest existing ancestor, and a dangling link is refused.
7. **Proxy URLs rebuilt** from scheme `https`, the host name, path and query only; userinfo, port and fragment are
   dropped. Redirects are held to the allowlist and rebuilt the same way. GET only, POST still dropped with `204`. 20 s
   timeout, the same User-Agent.
8. **`make app` re-extracts** Roland's web app from the verified zip into the bundle on every build, instead of
   trusting `build/roland/html`.
9. **Hardened runtime**: `codesign --force --sign - --options runtime`; `make install` verifies the signature
   (`codesign --verify --strict`) and the runtime flag. No entitlement turned out to be needed.

ADR-0003 records each fix and the residual risks.

### Build, version, CI

- `make` stays the entry point (`make help` lists the targets). `setup` checks the toolchain and takes Roland's web
  app out of its installer; every build and test treats compiler warnings as errors; `lint`/`format` use
  `swift format` with a `.swift-format` config at 120 columns. `make app` builds release arm64 and assembles
  `Contents/MacOS`, `Info.plist` (identifier `local.boss-tone-studio-mac.katana-mk2`, version), `Resources/roland-html`
  and `AppIcon.icns`, then signs.
- The icon is recoloured as in 0.1.x (Roland's dark background `#242424` → slate grey `#5C6370`, tolerance 48, partial
  shift on anti-aliased edges) by `packaging/make-icon.swift`, which `swift` runs as a script: it reads every image of
  Roland's `.icns` with ImageIO and writes a new `.icns`.
- The version lives in a `VERSION` file at the root; 0.2.0.
- CI, with macOS minutes costing ten times Linux ones (ADR-0012): `make lint` on Ubuntu in the official Swift
  container, pinned by digest to the minor version the code was last formatted with, for every pull request update,
  drafts included, and for pushes to `main`; `make test` on macOS only for pull requests that are ready for review and
  for pushes to `main`, since Network.framework, CoreMIDI and AppKit exist only there. Actions stay pinned to commit
  SHAs; a newer run cancels an older one. mise and uv are gone.
- ADR-0011 (the native app) supersedes ADR-0001 and the PyInstaller part of ADR-0008; ADR-0012 (the Swift-only
  toolchain) supersedes ADR-0009; ADR-0005 notes that the name stays the UID.

### Tests

- Swift Testing in `Tests/`: every Python test ported (the security rules against a real loopback server with a
  stand-in bridge, files, storage, close handshake, command names, no `startevent`, proxy allowlist, MIDI splitting,
  connect failure with a fake MIDI backend, Librarian import with plist fixtures, the lock), plus tests for the weak
  points the library addresses. No test creates a CoreMIDI client.
- The page side, which unit tests never run, was checked before the amp test: Roland's real `native.js` ran against the
  injected script in Node with a stub XHR, as for 0.1.1, and the page served by `--browser` was loaded in a WKWebView
  under its policy. That showed no policy violations or script errors; offline mode and Tone Central (the catalogue, a
  liveset's `.tsl`) worked and the YouTube player loaded; a negative control showed inline scripts, injected handlers
  and `javascript:` URLs blocked and a jQuery-inserted `<script>` running.
- The window and the CoreMIDI backend are checked by hand, with an amp (`doc/testing.md`).

### Done

1. `make check` passes locally; on the draft pull request CI's lint passes, and its macOS tests run once the pull
   request is ready for review.
2. The built `.app` (`BTS_TRACE=1`, a copy of the data folder) ran with the KATANA-ARTIST MkII and the KATANA-HEAD
   MkII. The checks of `doc/testing.md` › With an amp were split between the two amps, as the README's Verified
   amplifiers records, and Roman confirmed the window checks.
3. The bundle is 14 MB, 13 MB of which is Roland's web app, signed ad hoc with the hardened runtime.
4. Every Python test has a Swift Testing counterpart. `bts/`, `tests/`, `mise.toml`, `pyproject.toml`,
   `requirements*.txt`, `packaging/app.spec` and `packaging/make_icon.py` are removed; README, AGENTS.md, `doc/` and
   CHANGELOG (0.2.0) describe the Swift app.

The native app installs over 0.1.x under the same name. The fallback is the `v0.1.1` tag (`make setup app install` on
it).
