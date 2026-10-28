# Bridge protocol

How Roland's KATANA MkII web app talks to its native shell, and how this project answers it. Everything here comes
from Roland's plain-text `js/lib/native.js` and the page's other scripts, and from observing the app in use. The code
in `bts/` follows this document.

## Transport in `native.js`

`native.js` has a Mac branch: when `navigator.userAgent` contains `roland.quattro` **and** `window.$$xhrport` exists:

- `_()` is a **synchronous** `GET 'http://localhost:' + $$xhrport + '/' + method` + `';' + encodeURIComponent(arg1)`
  + `',' + encodeURIComponent(arg2)`; the response is decoded.
- `_1()` → `webkit.messageHandlers.quattro1` (player/recorder only; the MkII does not use it).
- `_2()` → `webkit.messageHandlers.quattro2.postMessage`, used by **`midi.send`**. Only Roland's shell registers these
  handlers, so `$native.midi.send` is replaced after `native.js` loads (sync XHR to `$$midi_send`).
- `_('$$app_startevent')` runs at load; when it returns `undefined` (`v`), the default `$event.start` stays:
  `setInterval(pumpevent, 50)`, which calls `$$app_getevent` until it returns `undefined`.

Response (`decode`): the first character is the type — `v` undefined, `b` false / `b1` true, `d` int, `f` float,
`s` string. Anything else → `throw new Error(rest)` (the server answers `e<message>` for errors).

An event from `$$app_getevent` is `prop\ftype\farg1\farg2…` (form-feed separated), dispatched to
`$native[prop].event[type](args…)`.

Argument parsing: path `/$$cmd;a1,a2`. No `;` → no arguments; `;` with nothing after it → `['']`. Arguments are
`encodeURIComponent`-ed, so a comma inside one is `%2C` and splitting on `,` is safe. Parse the raw path; do not rely
on platform URL helpers to split out the `;arguments`.

Large writes (an All Data Backup, a liveset with 15 patches) outgrow a GET URL — Python's `http.server` caps the request
line at 64 KB and answers `414` — so `fs.writeString` and the writing form of `app.storage2` are replaced to
`POST /<token>/$$cmd` with a JSON array of arguments as the body. The page script converts every argument to a string
first, as GET's percent-encoding does: the Librarian passes numeric liveset IDs. Both calls throw in the page when
the bridge answers anything but HTTP 200, like `native.js` does for an undecodable answer.

## What is injected into `index.html`

Roland's files stay unchanged; only the HTTP response for `index.html` gets two `<script>` blocks.

Before `<script src="js/lib/native.js"></script>` (the marker must exist, else the server refuses the version):

- `window.$$xhrport = '<port>/<token>';` — `native.js` builds every URL from it, so the token after the port becomes
  the path prefix of every command (`/<token>/$$cmd`).
- `navigator.userAgent` overridden with `Object.defineProperty` to append `roland.quattro(Mac)`.
- `window.onerror` → `POST /<token>/log` (JS errors logged on the server).

After `native.js`:

- `$native.midi.send` → sync GET `$$midi_send` (keeps MIDI order);
- `$native.fs.writeString` and the write form of `$native.app.storage2` → sync POST;
- a `$.ajaxPrefilter` that sends absolute URLs to `/<token>/proxy?url=…` (Tone Central, see below).

The page loads from `http://localhost:<port>/index.html` (not `127.0.0.1`): `native.js` calls `localhost`, so anything
else is cross-origin. The server listens on both `127.0.0.1` and `::1` on the same port (another port is picked if
`::1` is taken) and keeps connections alive, since the page polls every 50 ms.

## Commands the MkII app calls

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
| `fs_exec;url` | open in the browser — `http(s)://` only |
| `fs_readString;path`, `fs_writeString;path,text` | permitted paths only (see Security) |
| `fs_openfilename[;["tsl"]]` | asynchronous dialog → event `fs\fopenfilename\f<path>` |
| `fs_savefilename;name,ext` | asynchronous dialog → event `fs\fsavefilename\f<path>` (extension appended) |
| `midi_inendpoints`, `midi_outendpoints` | JSON array of `{"MIDIEntityNameKey", "MIDIDeviceNameKey", "MIDIEndpointUIDKey"}` |
| `midi_inconnect;json`, `midi_outconnect;json` | open the port by `MIDIEntityNameKey`; failure → event `midi\fconnectfailed\f<json>` |
| `midi_indisconnect`, `midi_outdisconnect` | close |
| `midi_send;HEX` | hex without spaces → bytes → split into whole messages (sysex `F0…F7`) → send |
| `midi_panel` | no-op |

Behaviour worth knowing:

- Inputs and outputs are paired by an identical `MIDIEntityNameKey`, so input and output port names must match.
- The page remembers the chosen device by `MIDIEndpointUIDKey`; without one, every port matches. rtmidi exposes no
  CoreMIDI unique ID, so the port name serves as the UID.
- Incoming MIDI: event `midi\fmessage\f<HEX, uppercase, no spaces>\f<timestamp ms>`; one message per event; whole
  sysex.
- Hot-plug: port lists are compared every ~1.5 s → event `midi\fchanged`.
- The page sends its MIDI queue one message at a time, paced by its own interval.
- Closing the window: the shell sends the page `app\fcommand\fexit`; the page sends DT1 `7F 00 00 01 = 00` (editor
  communication mode off) and calls `$$app_exit` 500 ms later. The pywebview `closing` handler cancels the first close,
  queues the event and arms a 2 s fallback.
- A POST to `index.html` is the page's usage telemetry → `204`, forwarded nowhere.
- Tone Central fetches from `api.roland.com`, `bosstonecentral.com`, YouTube and SoundCloud, whose servers send no CORS
  headers; the proxy fetches them over HTTPS from that allowlist only (redirects checked too). SoundCloud's API rejects
  the page's old client ID, so audio previews stay off.

## Amp behaviour (observed)

- CoreMIDI ports: `KATANA` and `KATANA DAW CTRL`; the editor uses `KATANA`.
- Identity Reply: `F0 7E 00 06 02 41 33 03 00 00 <model> 00 00 00 F7` — model `08` KATANA-HEAD MkII, `09`
  KATANA-ARTIST MkII.
- First launch: with no stored device, the page opens the device picker and connects nothing on its own.
- After connecting, the page turns editor mode on (DT1 `7F 00 00 01 = 01`) and off when closing (`= 00`).
- The first few DT1s use device ID `10` (the page's default), then the ID from the Identity Reply. Every parameter
  change from the page is sent twice.

## Roland's Librarian

- Roland's shell keeps `app.storage2` in NSUserDefaults:
  `~/Library/Preferences/jp.co.roland.BOSS-TONE-STUDIO-for-KATANA-MkII.plist`. The keys match the page's: `ID_LIST`
  (`{"list":[…]}`, the UI order), `CONFIRM_FLAG`, numeric keys = livesets (the value is a JSON string — copied
  verbatim), and `pref` = `app.storage` (guid, app version, MIDI device) — not taken over.
- The page takes a liveset's ID from `ID_LIST`, not from its content; at most 50 livesets (IDs 0–49) and 15 patches per
  liveset. Without `ID_LIST` the page creates an empty "LIVESET 1", so the import runs before the page loads.

## Security

The server can read and write files, so:

1. It listens on loopback only and checks `Host` ∈ {`localhost:P`, `127.0.0.1:P`, `[::1]:P`} on every request, HEAD
   included (DNS rebinding).
2. A per-launch token (`secrets.token_urlsafe(24)`), compared with `hmac.compare_digest`, guards every bridge route —
   `/<token>/$$…` (GET and POST), `/<token>/proxy`, `/<token>/log` → `403` without it. The page's usage telemetry —
   POSTs to its own URL, or to Roland through the proxy — is dropped with `204` and reaches nothing.
3. A foreign `Origin` and any `Sec-Fetch-Site` outside {absent, `same-origin`, `none`} are rejected on the bridge
   routes and on `index.html`, and every response forbids framing (`X-Frame-Options: DENY`,
   `frame-ancestors 'none'`), so other websites can neither drive the bridge nor open or frame the editor.
4. `fs_readString`/`fs_writeString` only reach the app's data or temp folder, or exactly a path the user picked in a
   file dialog during this session (resolved paths).
5. `fs_exec` opens `http(s)://` links only.
6. POST bodies are capped (64 MB) and need a valid `Content-Length`; page log lines are printed escaped and truncated.

The tests in `tests/` cover each rule (rules 1–3 and 6 against a real loopback server).
