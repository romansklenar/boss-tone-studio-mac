# BOSS TONE STUDIO for KATANA MkII — Apple Silicon

A native (arm64) Swift shell for Roland's BOSS TONE STUDIO for KATANA MkII 2.1.0 web app. Roland ships it for Intel
(`x86_64`) only; on macOS 27.2 the original no longer connects to the amp even under Rosetta (see
[Why this port exists](#why-this-port-exists)).

BOSS, KATANA and BOSS TONE STUDIO are trademarks of Roland Corporation. This is an independent project, not affiliated
with or endorsed by Roland.

The built app is **standalone**: Roland's web app (unchanged) is taken out of Roland's own installer download at build
time and bundled in, so Roland's x86_64 app never has to be installed and Rosetta is never needed. The repository
holds none of Roland's files, but the built app does — it is for personal use only; do not redistribute it.

## Why this port exists

- **Roland's editor is Intel-only.** BOSS TONE STUDIO for KATANA MkII 2.1.0, the current release on BOSS's site,
  ships only an `x86_64` binary; there is no Apple Silicon build for the MkII (Roland's Gen 3 editor, by contrast, is
  native). On Apple Silicon it runs only under Rosetta 2, which macOS does not include and installs on demand.
- **Rosetta is going away.** Apple supports it fully only through macOS 27; from macOS 28 only a subset for older
  games is to remain, and upgrading to macOS 27.0 already removed it
  ([sources](doc/research/2026-10-28-rosetta-on-macos-27.md)).
- **Even with Rosetta, it no longer works on macOS 27.2.** Roland's app launches and lists the amp, but never connects
  to it ("WRONG DEVICE") and shows an empty Librarian, although the library is intact on disk — the editor is unusable
  and a whole preset collection looks lost (tested 2026-10-28 with a KATANA-HEAD MkII).
- **The amps are fine.** KATANA MkII amps are widely used and Roland's USB driver is already universal (arm64), so only
  the editor stands between MkII owners and current macOS.

This port keeps Roland's editor UI exactly as it is and replaces only the Intel-only native shell with an arm64 one:
no Rosetta anywhere, it connects on macOS 27, it takes over the existing Librarian, and nothing in it depends on
Rosetta, so macOS 28 removing it should not affect it.

## How it works

Roland's `js/lib/native.js` hands every `$native.*` call to `window.$$app`, `$$midi`, `$$fs`… when the page defines
them. This project defines them so that each call becomes a synchronous `POST /<token>/$$command` to a local server,
and does what Roland's native shell does. It is a Swift app with no third-party code:

- `Sources/BossToneStudioCore/` — everything that needs neither a window nor a MIDI client, covered by unit tests:
  - `HTTPServer.swift`, `HTTPMessage.swift`, `Router.swift` — a small HTTP/1.1 server on `127.0.0.1` that serves
    Roland's web app unchanged under a per-launch token and applies the security rules.
  - `PageScript.swift` — the one `<script>` block added to the `index.html` response to connect the page to the
    bridge, and the page's Content-Security-Policy.
  - `Bridge.swift` — the commands the MkII app calls: storage, files, dialogs, MIDI, events, the close handshake;
    `FileAccess.swift` — which files the page may read and write.
  - `MidiController.swift`, `MidiMessages.swift`, `UMP.swift` — MIDI ports and messages, and their conversion to and
    from CoreMIDI's Universal MIDI Packets.
  - `Storage.swift` — the page's `app.storage2` (one file per key), written atomically; shared with the import.
  - `Proxy.swift` — fetches Tone Central's content from Roland's servers, which the page cannot reach directly (CORS).
  - `RolandImport.swift` — takes over the Librarian from Roland's app on the first launch.
- `Sources/BossToneStudio/` — the app: the AppKit window with a WKWebView, alerts and file dialogs
  (`WebWindow.swift`), CoreMIDI (`CoreMIDIBackend.swift`) and the command line (`main.swift`). When the window closes,
  the page first takes the amp out of editor mode, as in the original.

The protocol is described in [`doc/bridge-protocol.md`](doc/bridge-protocol.md), the design decisions in
[`doc/decisions/`](doc/decisions/) and the background research in [`doc/research/`](doc/research/).
Inspired by the [Linux port for KATANA Gen 3](https://github.com/Shesherd/BOSS-TONE-STUDIO-GEN-3-EXTENDED-FOR-LINUX).

## How the build works

1. **Toolchain** (`make setup`) — Apple's Command Line Tools: Swift 6, the macOS SDK, Swift Testing and
   `swift format`. No other tool or package is installed; `make swift-version` stops on any other major version of
   Swift ([ADR-0012](doc/decisions/ADR-0012-swift-toolchain-without-dependencies.md)).
2. **Roland's web app** (`make roland-assets`, part of setup) — `packaging/fetch-roland-assets.sh` downloads Roland's
   own macOS installer, `bts_katana2_m210.zip` from `static.roland.com` (the file BOSS's download page serves),
   checks its pinned SHA-256, expands the `.pkg` inside with `pkgutil --expand-full` — **nothing is installed or run**
   — and copies the web app (`html/`, 263 files, byte-identical to an installed copy) and the icon to `build/roland/`.
   The installer zip stays there as the backup copy; later builds reuse it and need no network.
3. **App bundle** (`make app`) — extracts Roland's web app again from the verified zip, recolours Roland's icon
   (`packaging/make-icon.swift`), builds the release executable for arm64 (compiler warnings are errors) and assembles
   `dist/BOSS TONE STUDIO for KATANA MkII (Apple Silicon).app`: the executable, `Info.plist` (`packaging/Info.plist`
   with the version from `VERSION`), the icon and Roland's web app. It signs the bundle ad hoc with the hardened
   runtime. The bundle is 14 MB, 13 MB of which is Roland's web app.
4. **Install** (`make install`) — checks the signature and the hardened runtime, then copies the bundle to
   `~/Applications`.

At runtime the app imports Roland's Librarian on the first launch, starts the local server on `127.0.0.1`, serves the
bundled web app with the bridge script injected into the `index.html` response, and opens a WKWebView window on
`http://127.0.0.1:<port>/<token>/index.html`. Nothing in `build/`, `dist/` or `tmp/` is committed.

## Setup and usage

Requirements: macOS 14 or later on Apple Silicon, Apple's Command Line Tools with Swift 6 (`xcode-select --install`),
and Roland's KATANA USB driver for the amp (its installer, "KATANA Driver Setup", is native arm64).

```bash
make setup          # check the Swift toolchain, take Roland's web app out of its installer (see How the build works)
make run            # the app window; `make browser` serves it to a browser, `make trace` logs the bridge
make app install    # build the standalone .app and copy it to ~/Applications
make help           # every target
```

On the first launch the app offers a device picker — choose **KATANA** (not "KATANA DAW CTRL"). It reconnects on its
own after that.

The bundle carries Roland's web app, so it needs no installed copy of Roland's app; its slate-grey icon tells it apart
from Roland's. The web app is looked up in `BTS_HTML_DIR`, then in the bundle, then in `build/roland/html`, then in
Roland's installed app. The executable (`Contents/MacOS/BossToneStudio`) also takes `--browser` (serve only and print
the page's URL) and `--import-roland` (see below); `BTS_TRACE=1` logs bridge commands and MIDI messages and enables the
Web Inspector.

### Other Macs

The bundle is arm64 only and targets macOS 14 (`minos 14.0` in the executable, `LSMinimumSystemVersion` 14.0), so it
should run on any Apple Silicon Mac with macOS 14 or later — tested only on macOS 27.2. The other Mac needs only
Roland's KATANA USB driver, not Roland's editor. The bundle is ad-hoc signed, not notarized: if it arrives with a
quarantine flag (download, AirDrop), open it once with right-click → Open.

Data (settings, livesets) lives in `~/Library/Application Support/BOSS TONE STUDIO for KATANA MkII (Apple Silicon)/`,
apart from Roland's app, in the same folder and file formats as 0.1.x. `BTS_HTML_DIR` and `BTS_DATA_DIR` override the
paths.

### Coming from Roland's app

On the first launch the port takes over the Librarian (livesets with patches) from Roland's app, which keeps it in
`~/Library/Preferences/jp.co.roland.BOSS-TONE-STUDIO-for-KATANA-MkII.plist`; the port only reads that file. The import
runs once (marker `roland-librarian-imported` in the data folder); `make roland-import` runs it again without
duplicating livesets already taken over, and refuses while the app is open. The Librarian holds at most 50 livesets.
Data of the older Adobe AIR editor for the original KATANA (`~/Library/Application Support/BOSS-TONE-STUDIO-for-KATANA`)
is not taken over.

## Verified amplifiers

Tested on macOS 27.2 (Apple Silicon), over USB, with Roland's KATANA USB driver, using the 0.1.x Python shell. The
native app (0.2.0) has not been run with an amp yet: its run with both amps is pending, and until then this table is
the record of 0.1.x.

| Amplifier | Identity Reply (model code) | Connects | Reads patches | Amp → app | App → amp | Librarian / files | Closing (editor mode off) | Date |
|---|---|---|---|---|---|---|---|---|
| KATANA-HEAD MkII | `41 33 03 … 08` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 2026-10-28 |
| KATANA-ARTIST MkII | `41 33 03 … 09` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 2026-10-28 |

The KATANA-ARTIST MkII row was re-run on the `$$app` transport of 0.1.1 in the app window: connect, MIDI both ways,
Tone Central, `.tsl` round trip, deleting a liveset, All Data Backup saved and restored, and closing. The checks used a
`make trace` log. The KATANA-HEAD MkII row dates from 0.1.0.

Other MkII models (KATANA-50 MkII, -100 MkII, -100/212 MkII) use model codes in the same range the editor accepts but
are untested; [`doc/testing.md`](doc/testing.md) lists what to check. Both amps above show up as the CoreMIDI port
`KATANA`; connect one amp at a time.

## Status

The table records 0.1.x. The native app (0.2.0) has so far been checked without an amp: run with `--browser` and
opened in a WKWebView, Roland's page loads under its security policy without errors, and offline mode and Tone Central
(catalogue, a liveset's `.tsl`, the YouTube player) work; the import took over Roland's 29 livesets; the built bundle
serves its own copy of the web app; and with an amp attached, but not connected, the port list shows `KATANA` and
`KATANA DAW CTRL` as before. SoundCloud is no longer proxied.

| Area | Status |
|---|---|
| Editor UI, offline mode | ✅ checked visually in a browser; in the window, start-up verified through the bridge |
| Storage (`app.storage`, `app.storage2`) | ✅ |
| MIDI with the amp (KATANA MkII over USB) | ✅ connecting, reading patches, changes from the app and from the amp's knobs |
| Remembering the chosen device | ✅ reconnects on the next launch |
| Closing the window (editor mode off, `$$app_exit`) | ✅ the page sends DT1 `7F 00 00 01 = 00` and calls `$$app_exit` itself |
| Librarian taken over from Roland's app | ✅ 29 livesets / 254 patches loaded in the original order |
| File dialogs | ✅ `.tsl` export and import (round trip identical), All Data Backup (81 KB) saved and restored to the amp; a Gen 3 `.tsl` is refused by Roland's code ("UNSUPPORTED DATA") |
| Deleting livesets/patches | ✅ fixed (the page passes numeric IDs); liveset delete verified in the window, patch delete in the browser (persists across reload) |
| Tone Central | ✅ through a local proxy: catalogue, details, YouTube preview, adding a liveset; SoundCloud previews ❌ (Roland's old API key returns 401) |
| `.app` bundle | ✅ `make app`: standalone (serves the bundled web app, nothing open under `/Applications/BOSS`), arm64, "(Apple Silicon)" name, grey icon |

## Next steps

1. **Gen 3 → MkII preset converter** — a separate project. Roland supports MkII presets on a Gen 3 amp but not the
   other way round; Gen 3 presets store some effects per colour (green/red/yellow) and use different amp types, so a
   conversion would be lossy in known places.
2. **Gen 3 amps** — out of scope: Roland ships a native Apple Silicon editor for the Gen 3.

## Licensing

*Not legal advice.* This records why the setup is meant to stay within Roland's licence and the law, and where it is
not clear-cut.

**Roland's terms.** BOSS TONE STUDIO is free to download after accepting the Roland Software License Agreement on
[BOSS's download page](https://www.boss.info/global/support/by_product/katana-50_mk2/updates_drivers/925b13ac-a4af-4069-b09c-836b956375e7/).
In short: use on one computer at a time; one backup copy; no modifying, reverse engineering, decompiling or
disassembling; no distributing, selling, lending or sublicensing; Roland owns the software and its copyrights. The
installer itself contains no licence text; Roland's files carry "Copyright Roland Corporation. All rights reserved."

How this project relates to each point:

- **Repository** — only our own code; no Roland file is committed, so the repository can be shared. Everyone who
  builds it downloads their own copy from Roland's official URL, as they would from BOSS's site.
- **Accepting the agreement** — the script downloads the zip directly and so never shows Roland's agreement. Whoever
  builds the app should read and accept it on the download page first; the build assumes they have.
- **One computer, one backup** — the app is built and used on your own Mac. The kept installer zip is the backup
  copy; `build/roland/` and the bundle are the working copy, as Roland's installer would put it in `/Applications`.
- **No modification** — Roland's files stay byte-identical (installer SHA-256, `diff` against an installed copy). At
  runtime the server adds one `<script>` block to the `index.html` *response* to connect the page to our bridge, the
  way a browser extension would; nothing on disk changes. This is the most debatable point: it does change how
  Roland's software behaves while it runs.
- **No reverse engineering** — the bridge was written from Roland's own plain-text JavaScript (`native.js` runs in the
  web view in readable form) and from watching the app's behaviour; neither the build nor the app decompiles or
  patches any Roland binary. In the EU, Directive 2009/24/EC also lets a lawful user observe, study and test how a
  program works (Art. 5(3)) to achieve interoperability, and contract terms to the contrary are void (Art. 8).
- **No distribution** — never share the built `.app`, `build/roland/` or the installer zip: they contain Roland's
  software and artwork (the recoloured icon is still Roland's). This is where the Linux port differs: it commits
  Roland's (modified) web app to its public repository and ships it in a `.deb`.
- **Trademarks** — "BOSS", "BOSS TONE STUDIO" and "KATANA" are Roland's; the app is named after the software it runs,
  for your own use, and says "(Apple Silicon)" so it is not mistaken for Roland's product.

## Weak points and risks

- **Roland's download can disappear or change.** New builds then fail on the SHA-256 check rather than use an
  unknown file. The kept `build/roland/bts_katana2_m210.zip` and any built app keep working.
- **Roland's online services can stop.** Tone Central depends on `api.roland.com` and `bosstonecentral.com` (live on
  2026-10-28); SoundCloud previews never worked (Roland's API key is rejected), so SoundCloud is not proxied.
  Everything else works offline.
- **The USB driver is Roland's.** `RDUSB01D8Midi.plugin` is universal today; if a future macOS drops that kind of
  CoreMIDI driver, the amp disappears from the port list and only Roland can fix it.
- **Web platform drift.** Roland's page relies on synchronous `XMLHttpRequest` (deprecated in browsers) and on
  WKWebView behaviour; a future WebKit could break it. The app uses only Apple's frameworks and toolchain, so a macOS
  or Command Line Tools update is what changes them; a release is re-tested with an amp.
- **Partial bridge.** Only the commands the MkII app calls are implemented. A call to anything else throws in the page,
  and the error is logged.
- **Limited testing.** Two amps on macOS 27.2 with 0.1.x, and the native app's amp run is still pending (see Verified
  amplifiers); other MkII models and macOS 14–26 are untested.
- **Signing.** The bundle is ad-hoc signed with the hardened runtime, not notarized. Built locally it opens normally;
  copied from elsewhere it needs right-click → Open, and a stricter future Gatekeeper could refuse it.
- **Local server with file access.** Mitigated as described under Security: nothing outside the page gets the token.
  Whatever runs in the page can still use the bridge: Roland's code, YouTube's player scripts, and any `<script>` in
  Tone Central's content, which jQuery runs (see the residual risks in
  [ADR-0003](doc/decisions/ADR-0003-bridge-security.md)).
- **Legal grey zone.** The runtime script injection is the point that rests on interoperability rather than on
  Roland's terms (see Licensing). Keeping the built app private keeps the exposure small.

## Security

The server can read and write files, so it listens on `127.0.0.1` only, checks the `Host`, serves the page, its files
and the bridge only under a per-launch secret token that it never hands out, holds the page to a
Content-Security-Policy, reaches files only in the app's own folders or where the user pointed a file dialog (a file
picked to open is read only), fetches only from Tone Central's hosts, and opens only web links. The rules are in
[`doc/bridge-protocol.md`](doc/bridge-protocol.md#security), their tests in [`doc/testing.md`](doc/testing.md).
