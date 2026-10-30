# Changelog

Notable changes per release. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2026-10-31

### Fixed

- Logging out, restarting or shutting down no longer stops at the editor ("cancelled logout"): the app waits until the
  page has taken the amp out of editor mode, at most about 2 s, and then quits (ADR-0017).
- An export to `.tsl` or `.alb` is saved with one extension, not as `name.tsl.tsl`: for a file type no app on the Mac
  declares, the save dialog saves the name as typed. A name typed without the extension gets it added afterwards, and
  then without the dialog's question before replacing a file of that name.
- The app runs from Xcode next to an installed copy, with its own data folder in the checkout (ADR-0013); a relative
  `BTS_DATA_DIR` or `BTS_HTML_DIR` and a leading `~` work for a bare executable.

### Changed

- The page fetches every queued event in one request instead of one request per event (ADR-0014), and the MIDI
  backend is called from a serial queue with no lock held (ADR-0015).
- Verified with a KATANA-HEAD MkII on macOS 27.2.

### Security

- A file the page reads or writes is opened as a descriptor and checked where it really leads, so a link swapped in
  after the check is not followed; a save replaces the file atomically through its folder, creates missing folders the
  same way, and keeps the replaced file's permission bits without exposing its new content meanwhile (ADR-0016).

## [1.0.0] - 2026-10-29

### Added

- When WebKit ends the page's process (a crash, or memory pressure), the window loads the page again, which reconnects
  to the amp, instead of staying blank.

### Changed

- The app is native Swift: an AppKit window with a WKWebView, an HTTP server on Network.framework and CoreMIDI, with no
  third-party code. The bundle shrinks from 38 MB to 14 MB, 13 MB of which is Roland's web app.
- Building needs only Apple's Command Line Tools with Swift 6; `make setup` checks the version.
- The same app name, bundle identifier, icon, data folder and file formats as 0.1.x, and MIDI ports named as before,
  since the page stores the name as the device's ID. Ports with connections drawn in Audio MIDI Setup and names with
  non-ASCII characters, which python-rtmidi decoded as MacRoman, are named differently: such a device goes through the
  device picker once.
- MIDI hot-plug follows CoreMIDI's notifications instead of polling every 1.5 s.
- Storage and file reads keep line endings as stored.
- The version lives in `VERSION`.
- Verified with a KATANA-HEAD MkII and a KATANA-ARTIST MkII on macOS 27.2.

### Fixed

- The save dialog adds the file's extension itself, so its question before replacing a file is about the file that is
  written; when the typed name lacked the extension, the bridge used to add it only after the dialog had closed.

### Security

- The page and its files are served under the per-launch token as well, so the server no longer gives the token to
  any local program that asks.
- The server binds `127.0.0.1` only and refuses `localhost` and `[::1]`; the window opens the page on `127.0.0.1`.
- The page runs under a Content-Security-Policy that admits the bridge script by a per-response nonce. SoundCloud left
  the proxy's allowlist, and Roland's hosts must answer with JSON, which goes to the page as `application/json` or
  `text/plain`.
- MIDI ports whose names contain `<>&"'` are neither listed nor opened.
- The window opens no new windows: a clicked web link goes to the default browser, other schemes are dropped, and
  `window.open` without a click does nothing. The window stays on the page's origin, and frames load only `https` (or
  stay blank).
- A link reaches the browser only if it leads to another machine, since the page's own URLs carry the token: whether
  the page opens it with `fs_exec`, a click or a navigation, `localhost`, loopback and unspecified addresses in any
  spelling, links without a host and links with userinfo are refused (bridge protocol, rule 6).
- A file picked in the open dialog is read only; only paths picked in the save dialog are writable. A dangling link
  in a path is refused.
- The proxy rebuilds every URL and redirect from `https`, the host name, path and query, dropping userinfo, port and
  fragment.
- `make app` extracts Roland's web app again from the SHA-256-checked installer zip on every build.
- The bundle is signed with the hardened runtime, and `make install` checks the signature and the runtime flag.
- A connection is closed after 30 s without a complete request, and requests that could be read two ways are refused.

### Removed

- The Python shell (pywebview, python-rtmidi, PyInstaller) and its tooling: mise, uv, ruff and the lock files.

## [0.1.1] - 2026-10-28

### Changed

- The bridge carries every command through `native.js`'s own `$$app` hook: one synchronous JSON POST per call. The
  forged user agent and the per-call overrides are gone.
- Bridge commands are accepted only as POST with a JSON content type.

### Security

- Every spelling of the editor page's path now goes through the origin check; `/./index.html` used to slip past it.
- Refused requests no longer write the token to the log, and request paths can no longer forge log lines.
- `make deps` no longer trusts `mise.toml` by itself (run `mise trust` once), and every package sync checks the lock's
  hashes.

## [0.1.0] - 2026-10-28

First release.

### Added

- Native arm64 shell running Roland's unchanged BOSS TONE STUDIO for KATANA MkII 2.1.0 web app. It needs no Rosetta
  and no installed copy of Roland's app.
- A local HTTP bridge for Roland's `native.js` protocol, covering storage, files, CoreMIDI through python-rtmidi, and
  events. The bridge is locked to the served page by a per-launch token, Host and Origin checks, and a file allowlist.
- Takes over Roland's Librarian on the first launch; `make roland-import` repeats the import.
- Tone Central through an HTTPS proxy limited to an allowlist of hosts.
- A standalone `.app` built from Roland's installer download, checked against a pinned SHA-256.
- Verified with a KATANA-HEAD MkII and a KATANA-ARTIST MkII on macOS 27.2.

[1.0.1]: https://github.com/romansklenar/boss-tone-studio-mac/releases/tag/v1.0.1
[1.0.0]: https://github.com/romansklenar/boss-tone-studio-mac/releases/tag/v1.0.0
[0.1.1]: https://github.com/romansklenar/boss-tone-studio-mac/releases/tag/v0.1.1
[0.1.0]: https://github.com/romansklenar/boss-tone-studio-mac/releases/tag/v0.1.0
