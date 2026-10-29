# ADR-0011: A native Swift app instead of the Python shell

Status: accepted, 2026-10-29; supersedes [ADR-0001](ADR-0001-python-shell-around-rolands-web-app.md) and the
PyInstaller part of [ADR-0008](ADR-0008-standalone-bundle-from-rolands-installer.md)

## Context

The 0.1.x Python shell works with both verified amps, but its bundle is 38 MB because it carries its own Python, and
building it needs mise, uv, a pinned Python, python-rtmidi compiled from source and PyInstaller. ADR-0001 kept a native
shell (WKWebView + embedded HTTP server + CoreMIDI) as the later step, with `doc/bridge-protocol.md` as what it must
implement. [ADR-0003](ADR-0003-bridge-security.md) listed weak points still to fix.

## Decision

Rewrite the shell as one Swift package with no package dependencies, only Apple's frameworks:

- Library `BossToneStudioCore`, everything testable without a window or a MIDI client: the HTTP server
  (Network.framework, `127.0.0.1` only) and its router, the bridge's command table and event queue, storage, file
  access, the Tone Central proxy, MIDI message handling and Universal MIDI Packets, the Librarian import and the
  data-folder lock.
- Executable `BossToneStudio`: the AppKit window with a WKWebView, alerts and file dialogs, the CoreMIDI backend and
  the command line (`--browser`, `--import-roland`).
- The bridge keeps 0.1.1's protocol ([ADR-0010](ADR-0010-native-js-app-hook-as-the-transport.md)), commands, answers,
  event queue (capped at 10,000) and close handshake. Commands answer synchronously, like the page's synchronous XHR;
  shared state sits behind `OSAllocatedUnfairLock`.
- CoreMIDI directly, through its current API: MIDI 1.0 Universal MIDI Packets (`MIDIInputPortCreateWithProtocol`,
  `MIDISendEventList`). Converting between bytes and packets is a pure function in the library.
- Users carry on: the same app name, bundle identifier, icon, data folder and on-disk formats (`storage.json`,
  `storage2/<key>` with the key quoted as Python's `quote(key, safe="")` did, `roland-librarian-imported`, `app.lock`),
  port names ([ADR-0005](ADR-0005-port-name-as-endpoint-uid.md)) and log lines (`[bts]`, `[trace]`, `[js]`).
- ADR-0003's weak points are fixed in the rewrite (see its table). Every Python test gets a Swift Testing counterpart,
  and the Python code goes in the same branch once the native app has passed the amp run.

Where the port had to choose, it chose:

- Storage and file reads return the text as stored. 0.1.1 read in Python's text mode, which turned CR and CRLF into
  LF.
- Log lines always single-quote escaped text (`'it\'s'`), where Python's `repr` switched to double quotes.
- A path that does not exist yet is resolved through its nearest existing ancestor, and a dangling link at any level
  is refused; 0.1.1 followed a dangling link to its missing target and checked that.
- `window.open` without a user gesture does nothing; a click's new window goes to the default browser.
- Port names are built as rtmidi's `CreateEndpointName` builds them, not its connected-endpoint variant; the two
  differ only for ports with connections drawn in Audio MIDI Setup. The name stays the UID (ADR-0005).
- Hot-plug follows CoreMIDI's setup-changed notification instead of a 1.5 s poll, and `midi\fchanged` is sent only when
  the port lists really changed.
- A connection is closed after 30 s without a complete request, and the HTTP parser refuses anything that could be
  read two ways (bare line feeds, folded headers, `Transfer-Encoding`, conflicting `Content-Length`).

## Consequences

- The bundle is 14 MB, 13 MB of which is Roland's web app and 676 KB the executable; 0.1.1's was 38 MB. It is still
  ad-hoc signed, now with the hardened runtime.
- Building needs only Apple's Command Line Tools ([ADR-0012](ADR-0012-swift-toolchain-without-dependencies.md)).
- The window's own behaviour (navigation, dialogs, closing) lives in the executable, which has no unit tests; it is
  checked by hand (`doc/testing.md`).
- The native app installs over 0.1.x under the same name. The fallback is the `v0.1.1` tag (`make setup app install`
  on it).
