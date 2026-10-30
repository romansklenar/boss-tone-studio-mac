# Native Swift App Implementation Plan

Status: executed on 2026-10-28 and 2026-10-29 on `feat/native-app`, released as 1.0.0. This file records how the work
was split and what changed on the way; the code, [ADR-0011](../decisions/ADR-0011-native-swift-app.md),
[ADR-0012](../decisions/ADR-0012-swift-toolchain-without-dependencies.md) and
[`doc/bridge-protocol.md`](../bridge-protocol.md) are the reference. Spec: the
[design](../design/2026-10-28-native-swift-app.md).

**Goal:** replace the Python shell with a dependency-free Swift app that runs Roland's unchanged MkII web app with the
same behaviour, data and protocol, and addresses ADR-0003's known weak points.

## How it ran

Fifteen tasks, each implemented and then reviewed on its own, with a round of fixes wherever a review found an
important issue; then a review of the whole branch and one more round of fixes. Tasks 1–13 ran unattended, Task 14 was
Roman's session with the amps, and Task 15 followed it. Until Task 15 the Python app stayed in the tree, runnable, as
the reference behaviour.

## Tasks

What each task delivered, and what its review changed:

1. **Package, Makefile, CI.**
2. **Storage and the data-folder lock** — a file that cannot be read or decoded throws instead of reading as missing,
   which would have made the Librarian look empty.
3. **Librarian import.**
4. **MIDI bytes and Universal MIDI Packets** — port names are checked for markup by Unicode scalar.
5. **MIDI controller.**
6. **File access** — a write could escape through a link above a folder that did not exist yet, so such a path
   resolves through its nearest existing ancestor, and dangling links are refused.
7. **Tone Central proxy** — every response carries `X-Content-Type-Options: nosniff`, so a body relabelled as text
   cannot be sniffed back into script.
8. **Bridge.**
9. **HTTP messages and the page script.**
10. **Router and server** — no `Referrer-Policy`: YouTube's embeds need a Referer, and WebKit's default already drops
    the path, and so the token, across origins.
11. **The app** — the bundle's web app is looked for only inside a `.app`, and `window.open` without a user gesture is
    blocked.
12. **Bundle, icon, signing.**
13. **Documents.**
14. **Amp run** (Roman), with both amps; the README's Verified amplifiers records which checks ran with each.
15. **Python removed** — every Python test mapped to a Swift one (43 of 43) before the Python code went.

The final review added tests for near misses of the token and for the proxy's timeout and User-Agent, made two
timer-based tests deterministic, and had `fs_exec` refuse links back to this Mac. Left open: while the page answers the
close handshake, the app cancels a logout or shutdown once (`.terminateCancel`); deferring the reply instead needs a
check with an amp.

## Risks the plan singled out

Each is pinned by a test: a SysEx split across CoreMIDI callbacks (`UMPTests`), a slow request holding up the poll
(`RouterTests`), awkward paths (`FileAccessTests`), 0.1.1's data read back byte for byte (`StorageTests`), and requests
arriving in pieces (`HTTPMessageTests`).
