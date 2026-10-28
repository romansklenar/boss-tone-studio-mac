# Bridge protocol

How Roland's KATANA MkII web app talks to its native shell, and how this project answers it. Everything here comes
from Roland's plain-text `js/lib/native.js` and the page's other scripts, and from observing the app in use. The code
in `bts/` follows this document.

## Transport in `native.js`

`native.js` routes every `$native.*` call through `_()` (`_1()`/`_2()` for a few) and picks the transport once, when it
loads. Its first branch applies whenever `window.$$app` exists, whatever the user agent:

- `_ = _1 = _2 = function (cmd, a1, a2)`: `'$$midi_send'` splits into object `$$midi` and method `send`, and
  `window.$$midi.send(a1, a2)` is called with only the arguments that are defined. Its return value is used as is
  (no `decode`).
- If `window.$$app.startevent` is defined, `native.js` switches to pushed events (`$event.trigger`). Otherwise the
  default `$event.start` stays: `setInterval(pumpevent, 50)`, which calls `$$app_getevent` until it returns
  `undefined`.

An event from `$$app_getevent` is `prop\ftype\farg1\farg2…` (form-feed separated), dispatched to
`$native[prop].event[type](args…)`.

The other branches (a `roland.quattro` user agent with `$$xhrport` → synchronous `GET /$$cmd;a1,a2` with typed
answers; WebKit message handlers for `midi.send`) are what Roland's own shell uses; this project does not use them
(ADR-0010).

## What is injected into `index.html`

Roland's files stay unchanged; only the HTTP response for `index.html` gets one `<script>` block, just before
`<script src="js/lib/native.js"></script>` (the marker must exist, else the server refuses the version). jQuery is
already loaded at that point. The block defines:

- `window.$$app`, `$$midi`, `$$midix`, `$$fs`, `$$security`, `$$notification`, `$$recognizer`, `$$barcode` and `$$util`,
  each a `Proxy` whose methods send the call to the bridge: a synchronous `POST /<token>/$$<object>_<method>` with
  `Content-Type: application/json` and the arguments as a JSON array of strings (`String(arg)`, as the URL transport
  would send them). The answer is the JSON-encoded result; `null` becomes `undefined`, and any status but `200` throws
  an `Error` with the response text. `startevent` stays undefined, so events are polled.
- a `window` `error` listener → `POST /<token>/log` (JS errors logged on the server).
- a `$.ajaxPrefilter` that sends absolute URLs to `/<token>/proxy?url=…` (Tone Central, see below).

The token lives only in that script's closure. The page loads from `http://localhost:<port>/index.html` and calls the
bridge by relative URL. The server listens on both `127.0.0.1` and `::1` on the same port, since WebKit may resolve
`localhost` to either (another port is picked if `::1` is taken). It keeps connections alive, since the page polls
every 50 ms.

## Commands the MkII app calls

| Command | Behaviour |
|---|---|
| `app_ready`, `app_control` | no-op (`'indicator start/stop'`, `'set_window_size:{"mode":"min","width":1160}'`) |
| `app_getevent` | pop one queued event, or `undefined` |
| `app_storage(data?)` | no argument: read the whole JSON (empty if missing); with an argument: write |
| `app_storage2(key, data?)` | per-key storage; `data == ''` deletes; keys such as `ID_LIST`, `CONFIRM_FLAG`, `0`… |
| `app_importfile`, `app_exportfile` | no-op (cloud import/export) |
| `app_exit` | disconnect MIDI, close the window |
| `fs_separator` | `/` |
| `fs_path('temporary' \| 'library')` | absolute path **with a trailing `/`** |
| `fs_exec(url)` | open in the browser — `http(s)://` only |
| `fs_readString(path)`, `fs_writeString(path, text)` | permitted paths only (see Security) |
| `fs_openfilename('["tsl"]'?)` | asynchronous dialog → event `fs\fopenfilename\f<path>` |
| `fs_savefilename(name, ext)` | asynchronous dialog → event `fs\fsavefilename\f<path>` (extension appended unless present) |
| `midi_inendpoints`, `midi_outendpoints` | JSON array of `{"MIDIEntityNameKey", "MIDIDeviceNameKey", "MIDIEndpointUIDKey"}` |
| `midi_inconnect(json)`, `midi_outconnect(json)` | open the port by `MIDIEntityNameKey`; failure → event `midi\fconnectfailed\f<json>` |
| `midi_indisconnect`, `midi_outdisconnect` | close |
| `midi_send(HEX)` | hex without spaces → bytes → split into whole messages (sysex `F0…F7`) → send |
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
  communication mode off) and calls `$$app_exit` 500 ms later. The pywebview `closing` handler cancels every close
  until then, queues the event once and arms a 2 s fallback.
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

1. It listens on loopback only and checks `Host` ∈ {`localhost:P`, `127.0.0.1:P`, `[::1]:P`} on every GET, HEAD and
   POST (DNS rebinding); other methods get `501`.
2. A per-launch token (`secrets.token_urlsafe(24)`), compared with `hmac.compare_digest`, guards every bridge route —
   `/<token>/$$…`, `/<token>/proxy`, `/<token>/log` → `403` without it. Commands are POST only (GET → `405`) and need
   `Content-Type: application/json` (`415` otherwise), which no cross-site form can send without a preflight. The page's
   usage telemetry — POSTs to its own URL, or to Roland through the proxy — is dropped with `204` and reaches nothing.
3. A foreign `Origin` and any `Sec-Fetch-Site` outside {absent, `same-origin`, `none`} are rejected on the bridge
   routes and on `index.html`, and every response forbids framing (`X-Frame-Options: DENY`,
   `frame-ancestors 'none'`), so other websites can neither drive the bridge nor open or frame the editor.
4. `fs_readString`/`fs_writeString` only reach the app's data or temp folder, or exactly a path the user picked in a
   file dialog during this session (resolved paths). The save dialog's extension must be 1–10 letters and digits,
   since it is appended to the picked path.
5. `fs_exec` opens `http(s)://` links only.
6. POST bodies are capped (64 MB): a malformed or oversized `Content-Length` → `400`. Command arguments must be a JSON
   array of strings (`400` otherwise). Page log lines are printed escaped and truncated.

The tests in `tests/` cover each rule except the loopback binding and log truncation (rules 1–3 and 6 against a real
loopback server).
