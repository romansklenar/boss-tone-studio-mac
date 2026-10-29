# Native Swift App Implementation Plan

Status: executed on 2026-10-28 and 2026-10-29 on `feat/native-app`, released as 0.2.0. This file records how the work
was split and what changed on the way; the code, [ADR-0011](../decisions/ADR-0011-native-swift-app.md),
[ADR-0012](../decisions/ADR-0012-swift-toolchain-without-dependencies.md) and
[`doc/bridge-protocol.md`](../bridge-protocol.md) are the reference. Spec: the
[design](../design/2026-10-28-native-swift-app.md).

**Goal:** replace the Python shell with a dependency-free Swift app that runs Roland's unchanged MkII web app with the
same behaviour, data and protocol, and addresses ADR-0003's known weak points.

## How it ran

Fifteen tasks, each implemented and then reviewed on its own, with a round of fixes wherever a review found an
important issue; then a review of the whole branch and one more round of fixes. Tasks 1–13 ran unattended, Task 14 was
Roman's session with the amps, and Task 15 followed it. Until Task 15 the Python app (`bts/`, `tests/`) stayed in the
tree, runnable, as the reference behaviour.

## Constraints that still hold

- macOS 14+, arm64 only, no package dependencies; build and test with the Command Line Tools alone,
  `swift-tools-version: 6.0`, compiler warnings as errors, Swift major version 6 (ADR-0012).
- The Makefile works around swiftlang/swift-build#1870 with `-plugin-path` until a Command Line Tools release has the
  fix, and probes `xcode-select -p` with its errors silenced so `make lint` runs in CI's Linux container.
- `swift`, `make test`, `make app` and anything touching CoreMIDI run outside Claude Code's sandbox; no test creates a
  CoreMIDI client.
- App name, bundle identifier, data folder, on-disk formats and log line shapes stay 0.1.1's, so users keep their
  Librarian and the trace checklist in `doc/testing.md` still applies.

## Tasks

1. **Package, Makefile, CI** — `Package.swift`, `.swift-format`, `VERSION`, the log helpers in 0.1.1's shapes, the
   Swift `build`/`test`/`lint`/`format`/`check`/`swift-version` targets, CI with lint on Linux and tests on macOS. On
   the case-insensitive disk `Tests/` was Python's `tests/`, so the Swift tests lived in `tests/` until Task 15.
2. **Storage and the data-folder lock** — `storage2` keys quoted as 0.1.1 quoted them, atomic writes, `flock` on
   `app.lock`. After review a file that cannot be read or decoded throws instead of reading as missing, which would
   have made the Librarian look empty.
3. **Librarian import** — 0.1.1's import from Roland's plist; each Python test ported with plist fixtures.
4. **MIDI bytes and Universal MIDI Packets** — message splitting, hex, the endpoint JSON, the markup filter on port
   names (compared by Unicode scalar after review), conversion to and from packets with SysEx reassembly; a SysEx
   without `F7` is closed, since a packet stream cannot leave one open.
5. **MIDI controller** — 0.1.1's `$native.midi` behaviour over a `MidiBackend` protocol; the lock rules between
   controller, backend and event queue are written on the protocol and on `Emit`.
6. **File access** — separate read and write sets. Review found a write escaping through a link above a folder that
   did not exist yet, so such a path resolves through its nearest existing ancestor, and dangling links are refused.
7. **Tone Central proxy** — the allowlist without SoundCloud, URLs and redirects rebuilt, Roland's hosts held to JSON.
   From its review every response carries `X-Content-Type-Options: nosniff` (added in Task 9), so a body relabelled
   as text cannot be sniffed back into script.
8. **Bridge** — 0.1.1's 23 commands, the event queue, dialogs through `BridgeHost` and the close handshake; a dialog's
   path is allowed in its resolved form, and `midi_indisconnect`/`midi_outdisconnect` still accept any arguments.
9. **HTTP messages and the page script** — the strict parser, responses with the fixed security headers (`204`, `304`
   and `1xx` without a body), token and nonce, and 0.1.1's injected script under a policy whose nonce is new for every
   response.
10. **Router and server** — every security rule, tested over a real loopback server; a connection closes after 30 s
    without a complete request. No `Referrer-Policy`: YouTube's embeds need a Referer, and WebKit's default already
    drops the path, and so the token, across origins.
11. **The app** — `AppPaths`, the CoreMIDI backend, the window and the command line. `BTS_HTML_DIR` is used as given;
    after review the bundle's web app is looked for only inside a `.app`, and `window.open` without a user gesture is
    blocked. The page side was checked by running Roland's `native.js` against the injected script in Node, and by
    loading the page in a WKWebView under its policy, which the controller ran instead of a browser pane.
12. **Bundle, icon, signing** — `packaging/make-icon.swift`, `packaging/Info.plist`, `make app` extracting Roland's
    web app again from the verified zip, an ad-hoc signature with the hardened runtime; 14 MB.
13. **Documents** — ADR-0011, ADR-0012, the amended ADRs, `doc/bridge-protocol.md`, `doc/testing.md`, README,
    AGENTS.md, CHANGELOG.
14. **Amp run** (Roman) — the built app with `BTS_TRACE=1` on a copy of the data folder, with the KATANA-ARTIST MkII
    and the KATANA-HEAD MkII. The checks were split between the two amps; the README's Verified amplifiers records
    which ran with each.
15. **Python removed** — every Python test mapped to a Swift one (43 of 43), the Python code and its tooling deleted,
    the Swift tests moved to `Tests/`. The push and the draft pull request followed the final review.

The final review's fixes: the close-handshake and slow-request tests stopped racing timers, `fs_exec` refuses links
back to this Mac, new tests for near misses of the token and for the proxy's timeout and User-Agent, and corrections
to the docs. Left open: while the page answers the close handshake, the app cancels a logout or shutdown once
(`.terminateCancel`); deferring the reply instead needs a check with an amp.

## Risks the plan singled out

Each is pinned by tests: a large SysEx split across CoreMIDI callbacks reaches the page whole and once (`UMPTests`);
a slow request on one connection does not hold up the 50 ms poll on another (`RouterTests`); paths with spaces and
non-ASCII names, and `/var` against `/private/var` (`FileAccessTests`); 0.1.1's data and non-ASCII liveset names read
back byte for byte (`StorageTests`); requests that arrive in pieces or two at once (`HTTPMessageTests`).

## Where things live

The README's How it works maps the source files, ADR-0011 the split between the library and the executable, and
`doc/testing.md` what the unit tests cover and what is checked by hand.
