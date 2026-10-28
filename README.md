# BOSS TONE STUDIO for KATANA MkII — Apple Silicon

A native (arm64) shell for Roland's BOSS TONE STUDIO for KATANA MkII 2.1.0 web app. Roland ships it for Intel
(`x86_64`) only; on macOS 27.2 the original no longer connects to the amp even under Rosetta (see
[Why this port exists](#why-this-port-exists)).

The built app is **standalone**: Roland's web app (unchanged) is taken out of Roland's own installer download at build
time and bundled in, so Roland's x86_64 app never has to be installed and Rosetta is never needed. The repository
holds none of Roland's files, but the built app does — it is for personal use only; do not redistribute it.

## Why this port exists

- **Roland's editor is Intel-only.** BOSS TONE STUDIO for KATANA MkII 2.1.0, the current release on BOSS's site,
  ships only an `x86_64` binary; there is no Apple Silicon build for the MkII (Roland's Gen 3 editor, by contrast, is
  native). On Apple Silicon it runs only under Rosetta 2, which macOS does not include and installs on demand.
- **Rosetta is going away.** Apple supports Rosetta fully only through macOS 27; from macOS 28 only a limited subset
  is to remain, aimed at older, unmaintained games built on Intel frameworks
  ([MacRumors, 2025-06-10](https://www.macrumors.com/2025/06/10/apple-to-phase-out-rosetta-2/), citing Apple's
  developer documentation). An editor that talks to a USB amp is not that kind of app, so from macOS 28 Roland's
  editor can be expected not to run at all.
- **Upgrading to macOS 27 removed Rosetta.** An upgrade to macOS 27.0 removed an installed Rosetta and did not restore
  it; macOS 27.2 stopped doing so ([Apple](https://support.apple.com/en-us/148830),
  [MacRumors, 2026-10-26](https://www.macrumors.com/2026/10/26/macos-27-2-stops-removing-rosetta/)). Users had to
  reinstall Rosetta just to start the editor.
- **Even with Rosetta, it no longer works on macOS 27.2.** Roland's app launches and lists the amp, but never connects
  to it ("WRONG DEVICE") and shows an empty Librarian, although the library is intact on disk — the editor is unusable
  and a whole preset collection looks lost (tested 2026-10-28 with a KATANA-HEAD MkII).
- **The amps are fine.** KATANA MkII amps are widely used and Roland's USB driver is already universal (arm64), so only
  the editor stands between MkII owners and current macOS.

This port keeps Roland's editor UI exactly as it is and replaces only the Intel-only native shell with an arm64 one:
no Rosetta anywhere, it connects on macOS 27, it takes over the existing Librarian, and nothing in it depends on
Rosetta, so macOS 28 removing it should not affect it.

## How it works

Roland's `js/lib/native.js` already has a macOS transport: when the user agent contains `roland.quattro` and the page
has `window.$$xhrport`, every `$native.*` call becomes a synchronous `GET http://localhost:<port>/$$command;arg1,arg2`.
This project does what Roland's native shell does:

- `bts/server.py` — a local HTTP server on loopback (IPv4 and IPv6). It serves Roland's HTML and adds two small
  `<script>` blocks to the `index.html` response (port + token + user agent; `midi.send` over XHR instead of
  `webkit.messageHandlers.quattro2`; large writes over POST). It implements the commands the MkII actually calls:
  storage, files, MIDI, events through `$$app_getevent`.
- `bts/midi.py` — CoreMIDI through `python-rtmidi` (arm64).
- `bts/roland_import.py` — takes over the Librarian from Roland's app on the first launch.
- `bts/__main__.py` — the window, through `pywebview` (Cocoa/WKWebView). When the window closes, the page first takes
  the amp out of editor mode, as in the original.

The full protocol, findings and design decisions are in
[`doc/plans/2026-10-27-reimplementation-handover.md`](doc/plans/2026-10-27-reimplementation-handover.md).
Inspired by the [Linux port for KATANA Gen 3](https://github.com/Shesherd/BOSS-TONE-STUDIO-GEN-3-EXTENDED-FOR-LINUX).

## How the build works

1. **Toolchain** (`make setup`) — mise installs the pinned Python 3.13.18, ruff and uv (`mise.toml`), creates `.venv`
   and installs the locked packages (`requirements.txt`: pywebview, python-rtmidi, pyobjc). python-rtmidi is compiled
   for macOS 14 (`MACOSX_DEPLOYMENT_TARGET`).
2. **Roland's web app** (`make roland-assets`, part of setup) — `packaging/fetch-roland-assets.sh` downloads Roland's
   own macOS installer, `bts_katana2_m210.zip` from `static.roland.com` (the file BOSS's download page serves),
   checks its pinned SHA-256, expands the `.pkg` inside with `pkgutil --expand-full` — **nothing is installed or run**
   — and copies the web app (`html/`, 263 files, byte-identical to an installed copy) and the icon to `build/roland/`.
   The installer zip stays there as the backup copy; later builds reuse it and need no network.
3. **App bundle** (`make app`) — installs the build-only packages (`requirements-app.txt`: PyInstaller, Pillow),
   recolours Roland's icon (`packaging/make_icon.py`) and runs PyInstaller (`packaging/app.spec`), which bundles
   Python, our code, the native modules and Roland's web app into
   `dist/BOSS TONE STUDIO for KATANA MkII (Apple Silicon).app` (arm64, ad-hoc signed, ~38 MB).
4. **Install** (`make install`) — copies the bundle to `~/Applications`.

At runtime the app starts the local server, imports Roland's Librarian on the first launch, serves the bundled web
app with the bridge scripts injected into the `index.html` response, and opens a WKWebView window on it. Nothing in
`build/`, `dist/` or `tmp/` is committed.

## Setup and usage

Requirements: macOS on Apple Silicon, [mise](https://mise.jdx.dev), the Xcode Command Line Tools (`python-rtmidi`
builds from source), and Roland's KATANA USB driver for the amp (its installer, "KATANA Driver Setup", is native
arm64).

```bash
make setup          # pinned Python, ruff and uv (mise.toml), locked packages (requirements.txt), Roland's web app
make roland-assets  # (part of setup) web app + icon from Roland's installer zip (kept), SHA-256 checked, no install
make run            # the app window
make browser        # server only; prints a URL for a browser (no file dialogs)
make trace          # the window, logging every bridge command and MIDI message
make import-roland  # re-import the Librarian from Roland's app
make check          # lint + tests
```

On the first launch the app offers a device picker — choose **KATANA** (not "KATANA DAW CTRL"). It reconnects on its
own after that.

`make app` builds `dist/BOSS TONE STUDIO for KATANA MkII (Apple Silicon).app` and `make install` copies it to
`~/Applications`. Its icon is Roland's with a slate-grey instead of a black background (`packaging/make_icon.py`), so
it is easy to tell from the original. The bundle carries its own Python 3.13 and Roland's web app, so it depends on
neither the system Python (macOS ships none; `/usr/bin/python3` is a Command Line Tools shim, 3.9.6 here) nor
Roland's installed app. Without the bundle, the web app is looked up in `BTS_HTML_DIR`, then `build/roland/html`,
then Roland's installed app.

### Other Macs

The bundle is arm64 only and every binary in it targets macOS 14 or older (`MACOSX_DEPLOYMENT_TARGET` in
`mise.toml`), so it should run on any Apple Silicon Mac with macOS 14 to 27 — checked from the binaries' metadata,
tested only on macOS 27.2. The other Mac needs only Roland's KATANA USB driver, not Roland's editor. The bundle is
ad-hoc signed, not notarized: if it arrives with a quarantine flag (download, AirDrop), open it once with right-click
→ Open.

Data (settings, livesets) lives in `~/Library/Application Support/BOSS TONE STUDIO for KATANA MkII (Apple Silicon)/`,
apart from Roland's app. `BTS_HTML_DIR` and `BTS_DATA_DIR` override the paths.

### Coming from Roland's app

On the first launch the port takes over the Librarian (livesets with patches) from Roland's app, which keeps it in
`~/Library/Preferences/jp.co.roland.BOSS-TONE-STUDIO-for-KATANA-MkII.plist`; the port only reads that file. The import
runs once (marker `roland-librarian-imported` in the data folder); `make import-roland` runs it again without
duplicating livesets already taken over. The Librarian holds at most 50 livesets.

## Verified amplifiers

Tested on macOS 27.2 (Apple Silicon), over USB, with Roland's KATANA USB driver.

| Amplifier | Identity Reply (model code) | Connects | Reads patches | Amp → app | App → amp | Librarian / files | Closing (editor mode off) | Date |
|---|---|---|---|---|---|---|---|---|
| KATANA-HEAD MkII | `41 33 03 … 08` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 2026-10-28 |
| KATANA-ARTIST MkII | `41 33 03 … 09` | ✅ | ✅ | ✅ | ⏳ not yet seen in the trace | — (same code paths, not repeated) | ✅ | 2026-10-28 |

Other MkII models (KATANA-50 MkII, -100 MkII, -100/212 MkII) use model codes in the same range the editor accepts but
are untested. Both amps above show up as the CoreMIDI port `KATANA`; connect one amp at a time.

## Status

| Area | Status |
|---|---|
| Editor UI, offline mode | ✅ checked visually in a browser; in the window, start-up verified through the bridge |
| Storage (`app.storage`, `app.storage2`) | ✅ |
| MIDI with the amp (KATANA MkII over USB) | ✅ connecting, reading patches, changes from the app and from the amp's knobs |
| Remembering the chosen device | ✅ reconnects on the next launch |
| Closing the window (editor mode off, `$$app_exit`) | ✅ the page sends DT1 `7F 00 00 01 = 00` and calls `$$app_exit` itself |
| Librarian taken over from Roland's app | ✅ 29 livesets / 254 patches loaded in the original order |
| File dialogs | ✅ `.tsl` export and import (round trip identical), All Data Backup (81 KB); a Gen 3 `.tsl` is refused by Roland's code ("UNSUPPORTED DATA"); restoring a backup not tested |
| Deleting livesets/patches | ✅ fixed (the page passes numeric IDs); liveset delete verified in the window, patch delete in the browser (persists across reload) |
| Tone Central | ✅ through a local proxy: catalogue, details, YouTube preview, adding a liveset; SoundCloud previews ❌ (Roland's old API key returns 401) |
| `.app` bundle | ✅ `make app`: standalone (serves the bundled web app, nothing open under `/Applications/BOSS`), arm64, "(Apple Silicon)" name, grey icon |

## Next steps

1. **Restore from an All Data Backup** — the one file dialog not tested yet (it rewrites every patch in the amp).
2. **Unit tests for the server** — response encoding, request parsing, `split_messages`, the proxy allowlist and the
   security checks (token, Host, Origin, file allowlist), so a rebuild has a safety net beyond curl.
3. **Gen 3 → MkII preset converter** — a separate project. Roland supports MkII presets on a Gen 3 amp but not the
   other way round; Gen 3 presets store some effects per colour (green/red/yellow) and use different amp types, so a
   conversion would be lossy in known places.
4. **Gen 3 amps** — out of scope: Roland ships a native Apple Silicon editor for the Gen 3.
5. **Option C** (later) — a native rewrite (WKWebView + embedded HTTP server + CoreMIDI, no Python): a small signed
   app instead of a 38 MB bundle with its own Python.

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
  runtime the server adds two `<script>` blocks to the `index.html` *response* to connect the page to our bridge, the
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
  2026-10-28); SoundCloud previews already fail (Roland's API key is rejected). Everything else works offline.
- **The USB driver is Roland's.** `RDUSB01D8Midi.plugin` is universal today; if a future macOS drops that kind of
  CoreMIDI driver, the amp disappears from the port list and only Roland can fix it.
- **Web platform drift.** Roland's page relies on synchronous `XMLHttpRequest` (deprecated in browsers) and on
  WKWebView behaviour; a future WebKit could break it. pywebview, pyobjc and PyInstaller are pinned; updating them
  needs a rebuild and a re-test.
- **Partial bridge.** Only the commands the MkII app calls are implemented; anything else answers "undefined" and is
  logged (`make trace`).
- **Limited testing.** KATANA-HEAD MkII and KATANA-ARTIST MkII on macOS 27.2 (see Verified amplifiers). Other MkII
  models, macOS 14–26 and restoring an All Data Backup are untested.
- **Signing.** The bundle is ad-hoc signed, not notarized. Built locally it opens normally; copied from elsewhere it
  needs right-click → Open, and a stricter future Gatekeeper could refuse it.
- **Local server with file access.** Mitigated as described under Security; a program already running as you could
  still read the token from `index.html`, but such a program has your access anyway.
- **Legal grey zone.** The runtime script injection is the point that rests on interoperability rather than on
  Roland's terms (see Licensing). Keeping the built app private keeps the exposure small.

## Security

The server can read and write files, so it:

- listens on loopback only and rejects a foreign `Host` (DNS rebinding);
- accepts `$$…` commands only with a secret token generated at each launch and sent only in `index.html` (as part of
  `$$xhrport`, so Roland's `native.js` puts it in every path itself); other websites do not know it;
- reads and writes files only in the app's own folders or where the user pointed a file dialog;
- opens only `http(s)` links through `fs.exec`.
