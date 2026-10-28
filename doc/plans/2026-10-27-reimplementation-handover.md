# Handover: BOSS TONE STUDIO for KATANA MkII on Apple Silicon — rebuilding from scratch

Written: 2026-10-27 · Updated: 2026-10-28 · Project: `~/Projects/boss-tone-studio-mac`

This document is for an agent in a new session who rebuilds the port from scratch, or continues it. It records the
user's decisions, everything learned about Roland's app, the environment traps and an action plan with verification.
The code in `bts/` is a **reference, not the specification**: the protocol described here is the source of truth.

---

## 1. Goal

Roland's BOSS TONE STUDIO for KATANA MkII 2.1.0 is `x86_64` only. On Apple Silicon it runs under Rosetta, which Apple
supports in full only through macOS 27. Beyond that, the original no longer works even under Rosetta on macOS 27.2
(see §4.5). Goal: a native arm64 app that runs **Roland's web app with its files unchanged** and serves its native
bridge (`$native.*`): MIDI over CoreMIDI, storage, files.

## 2. The user's decisions and preferences (binding)

- **Option B**: Python (arm64) + `pywebview` (Cocoa/WKWebView) + `python-rtmidi` (CoreMIDI). It is the proof of
  concept. Once MIDI and the UI work, a Swift rewrite (option C: WKWebView + embedded HTTP server + CoreMIDI) is a
  later step.
- **Location**: its own folder and repo, `~/Projects/boss-tone-studio-mac`.
- **Personal use only**: Roland's HTML is never modified or committed. At build time it is taken out of Roland's
  installer download (no install, no Rosetta) and bundled, so the built app is **standalone** and must not be
  redistributed. Name: "BOSS TONE STUDIO for KATANA MkII (Apple Silicon)"; icon: Roland's with a slate-grey
  background, so the two apps are told apart.
- **The user owns only a KATANA MkII**, not a Gen 3, so the Linux Gen 3 port and its `html-katana-gen-3.patch` are
  **not used**.
- Former users of Roland's app must land in their existing Librarian with no manual step (§4.4).
- Language: talk to the user in **Czech**; code, comments, docs (README, `doc/`) and commit messages in **English**.
- Commits: Conventional Commits with a capital letter (`Feat: …`, `Fix: …`, `Docs: …`), never amend, always new
  commits, trailer `Co-authored-by: Claude <noreply@anthropic.com>`.
- From the user's `CLAUDE.local.md`: every plan ends with open questions and includes a verification section
  (evidence, tests, in-browser checks for UI); when there are several approaches, recommend one with trade-offs and
  **let the user choose** before implementing.
- Claim only what was verified ("visually in the browser" is not "in the window").

## 3. What is on disk

| Item | Value |
|---|---|
| Roland's app | `/Applications/BOSS/KATANA MkII/BOSS TONE STUDIO for KATANA MkII.app` (2.1.0, `x86_64`, `jp.co.roland.BOSS-TONE-STUDIO-for-KATANA-MkII`) |
| Web app | `…app/Contents/Resources/html/` (`index.html`, `js/`, `css/`, `images/`, `export/`) |
| Bridge in JS | `html/js/lib/native.js` (Roland, 2015) |
| Roland's native shell | WKWebView + CoreMIDI + a local HTTP server; UA `roland.quattro(Mac)`, handlers `quattro1`/`quattro2` (both as `native.js` expects them) |
| Roland's settings / Librarian | `~/Library/Preferences/jp.co.roland.BOSS-TONE-STUDIO-for-KATANA-MkII.plist` (§4.4) |
| Roland's installer download | `https://static.roland.com/assets/media/zip/bts_katana2_m210.zip` (9.6 MB, SHA-256 `f3513e87…689b8`); its `.pkg` expands with `pkgutil --expand-full` without installing; the web app inside is byte-identical to the installed one — `packaging/fetch-roland-assets.sh` |
| MIDI driver | `/Library/Audio/MIDI Drivers/RDUSB01D8Midi.plugin` — universal (arm64); its installer "KATANA Driver Setup" is arm64 too, so no Rosetta at all |
| Other | `/Applications/BOSS/RC-10R/…` — also `x86_64`, out of scope |
| Toolchain | pinned in `mise.toml`: Python 3.13.18, ruff 0.17.3, uv 0.13.6 |

Reference Linux port (Gen 3): <https://github.com/Shesherd/BOSS-TONE-STUDIO-GEN-3-EXTENDED-FOR-LINUX> — its
`pywebview/server.py` speaks the same protocol and is a useful second source.

## 4. The bridge protocol (source of truth)

### 4.1 Transport in `native.js`

`native.js` has a Mac branch: when `navigator.userAgent` contains `roland.quattro` **and** `window.$$xhrport` exists:

- `_()` is a **synchronous** `GET 'http://localhost:' + $$xhrport + '/' + method` + `';' + encodeURIComponent(arg1)`
  + `',' + encodeURIComponent(arg2)`; the response is decoded.
- `_1()` → `webkit.messageHandlers.quattro1` (player/recorder only; the MkII does not use it).
- `_2()` → `webkit.messageHandlers.quattro2.postMessage`, used by **`midi.send`**. Only Roland's shell registers these
  handlers, so `$native.midi.send` has to be replaced after `native.js` loads (sync XHR to `$$midi_send`).
- `_('$$app_startevent')` runs at load; when it returns `undefined` (`v`), the default `$event.start` stays:
  `setInterval(pumpevent, 50)`, which calls `$$app_getevent` until it returns `undefined`.

Response (`decode`): the first character is the type — `v` undefined, `b` false / `b1` true, `d` int, `f` float,
`s` string. Anything else → `throw new Error(rest)` (we answer `e<message>` for errors).

An event from `$$app_getevent` is `prop\ftype\farg1\farg2…` (form-feed separated), dispatched to
`$native[prop].event[type](args…)`.

Server-side argument parsing: path `/$$cmd;a1,a2`. No `;` → no arguments; `;` with nothing after it → `['']`.
Arguments are `encodeURIComponent`-ed, so a comma inside one is `%2C` and splitting on `,` is safe. **Parse the raw
path yourself** (§4.5).

Large writes (an All Data Backup, a liveset with 15 patches) outgrow a GET URL: Python's `http.server` caps the
request line at 64 KB and answers `414`. So `fs.writeString` and the writing form of `app.storage2` are replaced to
`POST /<token>/$$cmd` with a JSON array of arguments as the body. **Convert every POSTed argument to a string**, as
GET's percent-decoding does: the Librarian calls `storage2(liveset.id, …)` with a numeric ID (deleting a liveset,
saving a patch), and an unconverted number broke deletes mid-way (stuck dialog, liveset left in `ID_LIST`).

### 4.2 What is injected into `index.html` (files stay unchanged; only the HTTP response changes)

Before `<script src="js/lib/native.js"></script>` (the marker must exist, else a hard "unsupported version" error):

- `window.$$xhrport = '<port>/<token>';` — because `native.js` builds the URL from it, the token after the port
  becomes the path prefix of every command (`/<token>/$$cmd`). That brings a secret into every call without touching
  Roland's HTML.
- `navigator.userAgent` overridden with `Object.defineProperty` (appends `roland.quattro(Mac)`); works in Chrome and
  WKWebView.
- `window.onerror` → `GET /__bts/log;<message>` (JS errors logged on the server).

After `native.js`: `$native.midi.send` → sync GET `$$midi_send` (keeps MIDI order); `$native.fs.writeString` and the
write form of `$native.app.storage2` → sync POST (§4.1).

The page must load from `http://localhost:<port>/index.html` (not `127.0.0.1`): `native.js` calls `localhost`, so
anything else is cross-origin. The server listens on **both 127.0.0.1 and ::1** on the same port.

### 4.3 Commands the MkII actually calls

| Command | Behaviour |
|---|---|
| `app_ready`, `app_control` | no-op (`'indicator start/stop'`, `'set_window_size:{"mode":"min","width":1160}'`) |
| `app_startevent` | return `v` (→ polling) |
| `app_getevent` | pop one queued event or `v` |
| `app_storage[;data]` | no argument: read the whole JSON (`s` + content, empty if missing); with an argument: write |
| `app_storage2;key[,data]` | per-key storage; `data == ''` deletes; keys such as `ID_LIST`, `CONFIRM_FLAG`, `0`… |
| `app_importfile`, `app_exportfile` | no-op (cloud import/export) |
| `app_exit` | disconnect MIDI, close the window |
| `fs_separator` | `/` |
| `fs_path;temporary` / `library` | absolute path **with a trailing `/`** |
| `fs_exec;url` | open in the browser — **`http(s)://` only** |
| `fs_readString;path`, `fs_writeString;path,text` | permitted paths only (§5) |
| `fs_openfilename[;["tsl"]]` | asynchronous dialog → event `fs\fopenfilename\f<path>` |
| `fs_savefilename;name,ext` | asynchronous dialog → event `fs\fsavefilename\f<path>` (append the extension) |
| `midi_inendpoints`, `midi_outendpoints` | JSON array of `{"MIDIEntityNameKey", "MIDIDeviceNameKey", "MIDIEndpointUIDKey"}` |
| `midi_inconnect;json`, `midi_outconnect;json` | open the port by `MIDIEntityNameKey`; failure → event `midi\fconnectfailed\f<json>` |
| `midi_indisconnect`, `midi_outdisconnect` | close |
| `midi_send;HEX` | hex without spaces → bytes → split into whole messages (sysex `F0…F7`) → send |
| `midi_panel` | no-op |

More findings:

- Inputs and outputs are paired in JS by an **identical `MIDIEntityNameKey`**, so input and output port names must
  match (they do with rtmidi/CoreMIDI).
- The page **remembers the chosen device by `MIDIEndpointUIDKey`** (`startInitSetting` in `midi_connect_controller.js`).
  Without it, `undefined === undefined` matches the first port. rtmidi exposes no CoreMIDI unique ID, so the port name
  serves as the UID.
- Incoming MIDI: event `midi\fmessage\f<HEX, uppercase, no spaces>\f<timestamp ms>`; one message per event; whole
  sysex (rtmidi `ignore_types(sysex=False, timing=True, active_sense=True)`).
- Hot-plug: compare port lists every ~1.5 s → event `midi\fchanged`.
- `MIDIController` in `js/common/midi_controller.js` sends its queue one message at a time, paced by
  `ProductSetting.interval`.
- Closing the window: the original sends the page `app\fcommand\fexit`; the JS sends DT1 `7F 00 00 01 = 00` (editor
  communication mode off) and calls `$$app_exit` 500 ms later. Implementation: the pywebview `closing` handler returns
  `False` (cancel), queues the event and arms a 2 s fallback close.
- A POST to `index.html` is Roland's usage telemetry (`log_manager.js`) → answer `204`, forward nothing.
- Tone Central calls `api.roland.com`, `bosstonecentral.com` (catalogue, `.tsl` files), SoundCloud and YouTube via
  `$.ajax({url})` → blocked by CORS (Roland's servers send no CORS headers; they were still live on 2026-10-28). Fix:
  the injected script rewrites absolute `$.ajax` URLs to `/<token>/__proxy?url=…`; `bts/proxy.py` fetches them over
  HTTPS from an allowlist of those hosts only (redirects checked too); POSTs (telemetry) get 204. SoundCloud's resolve
  API answers 401 to Roland's old client ID, so audio previews stay off.
- Roland's manual: `ProductSetting.manual` is empty, so "readme" opens nothing.

Findings from testing with the amp (2026-10-28, KATANA MkII over USB-C):

- CoreMIDI ports: `KATANA` and `KATANA DAW CTRL`; the right one is **`KATANA`**.
- Identity Reply: `F0 7E 00 06 02 41 33 03 00 00 08 00 00 00 F7` (Roland, KATANA MkII, device ID `00`).
- First launch: with no stored `input`/`output`, the page opens the device picker and connects nothing on its own.
- After connecting, the page turns editor mode on (DT1 `7F 00 00 01 = 01`) and off when closing (`= 00`).
- The first few DT1s go out with device ID `10` (Roland's default), then `00` after the Identity Reply. Every
  parameter change is sent twice — Roland's code does that, not the bridge.

### 4.4 Roland's Librarian and taking it over

- Roland's shell keeps `app.storage2` in **NSUserDefaults**:
  `~/Library/Preferences/jp.co.roland.BOSS-TONE-STUDIO-for-KATANA-MkII.plist`. The keys match the page's: `ID_LIST`
  (`{"list":[…]}`, the UI order), `CONFIRM_FLAG`, numeric keys = livesets (the value is `JSON.stringify(liveset)`,
  itself a JSON string — copy verbatim), and `pref` = `app.storage` (guid, appVersion, input/output) — **do not take
  it over** (the MIDI choice differs).
- The page takes a liveset's ID from `ID_LIST`, not from its content; `maxLivesetNum = 50` → IDs 0–49; at most 15
  patches per liveset. Without `ID_LIST` the page creates an empty "LIVESET 1" (ID 0), so the import must run before
  the page loads.
- The user's data: 29 livesets / 254 patches; a byte-identical backup is in `tmp/recovery-2026-10-28/` (gitignored,
  personal).
- `~/Library/Application Support/BOSS-TONE-STUDIO-for-KATANA` also exists — the old Adobe AIR BTS (KATANA MkI era:
  `Local Store/liveset.db`, downloaded `.tsl`). Different format; not taken over.
- Implementation: `bts/roland_import.py` — `import_once` (marker `roland-librarian-imported`; waits while the plist
  does not exist), `import_librarian` (de-duplicates by content, a colliding ID moves to the lowest free one, Roland's
  order first, limit 50), `make import-roland` / `./run --import-roland`. Tests: `tests/test_roland_import.py`.
- Verified: on the first launch with a fresh data folder, 29 livesets were imported, the page read them in the
  original order and wrote nothing; the user saw the whole library in the Librarian; the plist's SHA-256 is unchanged.

### 4.5 Roland's own app on macOS 27.2

Roland's x86_64 app still launches under Rosetta on macOS 27.2, but it lists the amp without connecting to it
("WRONG DEVICE") and shows an empty Librarian, although the Librarian data is intact in its plist (§4.4). This port
is unaffected. Lesson for any rebuild: parse the request path yourself (§4.1) instead of relying on platform URL
helpers to split out the `;arguments`.

## 5. Security (mandatory; came out of review)

The server can read and write files, so:

1. Listen on loopback only. On **every** request check `Host` ∈ {`localhost:P`, `127.0.0.1:P`, `[::1]:P`}
   (DNS rebinding).
2. A per-launch token (`secrets.token_urlsafe(24)`), compared with `hmac.compare_digest`; `/$$…` without it → `403`
   (GET and POST).
3. Also reject a foreign `Origin` and any `Sec-Fetch-Site` outside {absent, `same-origin`, `none`}.
4. `fs_readString`/`fs_writeString`: the resolved path must be inside the app's data or temp folder, or exactly a path
   the user picked in a file dialog during this session.
5. `fs_exec`: `http(s)://` only; nothing starting with `-`.

An automated review also reported "no Host check before `index.html`" — a false positive; the check is the first
line of `do_GET`.

## 6. Environment traps (Claude Code sandbox)

- The Bash sandbox **cannot create a CoreMIDI client** (`RtMidiError … -10833`; the process aborts in `libc++abi`),
  so anything touching MIDI runs with `dangerouslyDisableSandbox: true`.
- The sandbox blocks writes to `~/Library/Application Support`; in tests use `BTS_DATA_DIR=$PWD/tmp/…` (`tmp/` is in
  `.gitignore`).
- `python-rtmidi` 1.5.8 has no cp313 macOS arm64 wheel, so it builds from the sdist (meson), which needs `ar` through
  `xcrun`; `xcrun` cannot write its cache inside the sandbox → run `make setup` outside it. Needs the Xcode Command
  Line Tools.
- `mise exec`/`uv` inside the sandbox may fail on `~/.cache`; `UV_CACHE_DIR=$TMPDIR/uv-cache` helps.
- Outside the sandbox `$TMPDIR` differs (`/private/var/folders/…/T/`) from inside (`/tmp/claude-501`) → write logs to
  the project's `tmp/`.
- `rm -rf` outside the project was refused by the permission gate → do not delete there; use new `tmp/` subfolders.
- `open`/`osascript` do not work inside the sandbox; `pgrep`/`ps` report "Cannot get process list" → check processes
  outside it (`ps`, `lsof -iTCP`).
- System `python3` outside the sandbox may fail on `xcrun`; use `.venv/bin/python`.
- The built-in browser pane reaches `http://localhost:<port>` — good for visual UI checks in `make browser`. The native
  window cannot be seen; verify it indirectly (written storage, `BTS_TRACE=1` log).

## 7. Action plan (rebuild)

> Before building: settle the open questions in §9 with the user.

1. **Project skeleton** — `mise.toml` (pinned Python/ruff/uv, auto `.venv`), `pyproject.toml` (exact dependency pins,
   ruff config), `requirements.txt` lock (`make lock`), `Makefile` (`setup`, `run`, `browser`, `trace`,
   `import-roland`, `test`, `lint`, `format`, `check`), `.gitignore` (`.venv/`, `__pycache__/`, `tmp/`).
   *Verify:* `make setup` outside the sandbox; `.venv/bin/python -c 'import webview, rtmidi;
   print(rtmidi.MidiIn().get_ports())'`; `file …/_rtmidi*.so` = arm64.
2. **HTTP server + protocol** (§4.1, §4.2) — static files from Roland's folder, `index.html` injection, `$$cmd`
   dispatch over GET and POST, response encoding, event queue, telemetry POST → 204, `/__bts/log`.
   *Verify with curl:* `app_storage` read/write/read, `app_storage2` including delete with `''`, `fs_path;temporary`
   with `/`, unknown command → `v` + log, error → `e…`, a 300 KB POST write.
3. **Security** (§5). *Verify with curl:* no token / wrong token / foreign Host / foreign Origin /
   `Sec-Fetch-Site: cross-site` → 403; reading `/etc/hosts`, writing to `~`, `../` traversal, `fs_exec` of a local app
   or `-a…` → refused; writing to temp allowed.
4. **MIDI** (§4.3) — endpoints with UID, connect/disconnect, send with message splitting, incoming messages, hot-plug.
   *Verify without hardware:* `midi_inconnect` of a missing port → `connectfailed` event; unit test `split_messages`.
   *With hardware:* step 8.
5. **Window** — pywebview `gui="cocoa"`, `private_mode=False`, `storage_path` in the data folder,
   `min_size=(1160, 700)`, the `closing` handler (§4.3). `--browser` = server only + print the URL. Variables
   `BTS_HTML_DIR`, `BTS_DATA_DIR`, `BTS_TRACE`.
   *Verify:* run the window outside the sandbox with a fresh `BTS_DATA_DIR` → `storage.json` with
   `"appVersion":"2.1.0"`, no `[js]` errors in the log.
6. **Librarian import** (§4.4) — before the server starts; unit tests on synthetic plists.
   *Verify:* fresh data folder → all livesets read by the page in Roland's order (trace), plist unchanged.
7. **UI in the browser** — `make browser`, open the URL in the built-in browser: "DEVICE NOT FOUND" without the amp
   (= the MIDI listing went through the bridge), "OFFLINEMODE" → the editor renders; `/<token>/$$…` = 200 in the
   network log; only Tone Central CORS errors in the console.
8. **With the user and the amp** — `make trace`, pick `KATANA`, change a patch and a knob in both directions, close
   with the red button (`$$app_exit` from the page, not the 2 s fallback), export/import `.tsl`, All Data Backup and
   restore.
9. **README** with a status table — claim only what was verified.

## 8. Status of the reference implementation

| Area | Status |
|---|---|
| Protocol, storage, security | ✅ verified with curl |
| UI + offline mode | ✅ visually in the browser; in the window, start-up verified through the bridge (trace, written storage) |
| MIDI with the amp | ✅ connect, patch names, changes from the app and from the amp's knobs (trace) |
| Remembering the device | ✅ reconnects to `KATANA` on the next launch without the picker |
| Closing the window | ✅ `app.command exit` → DT1 `7F 00 00 01 = 00` → `$$app_exit`, exit code 0 |
| Librarian taken over from Roland's app | ✅ 29 livesets / 254 patches, seen by the user |
| File dialogs | ✅ `.tsl` export/import round trip identical, All Data Backup 81 KB, Gen 3 `.tsl` refused by Roland's code; restore not tested |
| Deleting livesets/patches | ✅ fixed (string POST arguments, unit test with a mutation check); liveset delete verified in the window, patch delete in the browser pane |
| Portability | every binary in the bundle targets macOS ≤ 14 (`MACOSX_DEPLOYMENT_TARGET=14.0`; python-rtmidi had picked up 27.0); tested on 27.2 only |
| Tone Central | ✅ through the proxy (catalogue, details, YouTube, adding a liveset); SoundCloud ❌ 401 |
| `.app` bundle | ✅ `make app` — PyInstaller (py2app fails on mise's python-build-standalone: `zlib` is built in) |

## 9. Open questions for the user

1. Why rebuild from scratch — another language (straight to option C / Swift), a cleaner architecture, or only to
   prove the plan is reproducible? Should the new code replace `bts/` or live next to it / on a branch?
2. Gen 3 → MkII preset converter (a separate project): which colour wins when a Gen 3 effect's colours differ, and
   which MkII amp type stands in for each Gen 3 amp type?
