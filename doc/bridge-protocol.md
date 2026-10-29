# Bridge protocol

How Roland's KATANA MkII web app talks to its native shell, and how this project answers it. Everything here comes
from Roland's plain-text `js/lib/native.js` and the page's other scripts, and from observing the app in use. The code
in `Sources/` follows this document.

## Transport in `native.js`

`native.js` routes every `$native.*` call through `_()` (`_1()`/`_2()` for a few) and picks the transport once, when it
loads. Its first branch applies whenever `window.$$app` exists, whatever the user agent:

- `_ = _1 = _2 = function (cmd, a1, a2)`: `'$$midi_send'` splits into object `$$midi` and method `send`, and
  `window.$$midi.send(…)` gets `a1, a2` when `a2` is defined, else `a1` when it is defined, else nothing. Its return
  value is used as is (no `decode`).
- If `window.$$app.startevent` is defined, `native.js` switches to pushed events (`$event.trigger`). Otherwise the
  default `$event.start` stays: `setInterval(pumpevent, 50)`, which calls `$$app_getevent` until it returns
  `undefined`.

An event from `$$app_getevent` is `prop\ftype\farg1\farg2…` (form-feed separated), dispatched to
`$native[prop].event[type](args…)`.

The other branches (a `roland.quattro` user agent with `$$xhrport` → synchronous `GET /$$cmd;a1,a2` with typed
answers; WebKit message handlers for `midi.send`) are what Roland's own shell uses; this project does not use them
(ADR-0010).

## What is injected into `index.html`

Roland's files stay unchanged; only the HTTP response for `index.html` gets one `<script>` block, carrying the
response's CSP nonce, just before `<script src="js/lib/native.js"></script>`. The marker must exist, else the server
answers `500` with a page that explains the version is not supported. jQuery is already loaded at that point. The
block defines:

- one method per bridge command, built from the server's command table: `app_storage2` becomes
  `window.$$app.storage2`, `midi_send` becomes `window.$$midi.send`. Each sends the call as a synchronous
  `POST /<token>/$$<command>` with `Content-Type: application/json` and the arguments as a JSON array of strings
  (`String(arg)`, as the URL transport would send them). The answer is the JSON-encoded result, and `null` becomes
  `undefined`. A `500` throws an `Error` with the bridge's message; any other status throws
  `bridge answered HTTP <status>`. There is no `app_startevent` command, so events are polled. A call the bridge does
  not implement throws a `TypeError` in the page, which the error listener logs.
- a `window` `error` listener → `POST /<token>/log` (JS errors logged on the server).
- a `$.ajaxPrefilter` that sends absolute URLs to `/<token>/proxy?url=…` (Tone Central, see below).

The page loads from `http://127.0.0.1:<port>/<token>/index.html`, and everything it reaches lies under that token: its
own files, which it loads by relative URL as before, and the bridge. The token is part of the page's URL and of the
script, so any script in the page can still call the methods. The server listens on `127.0.0.1` only, at a port the
system picks. It keeps connections alive, since the page polls every 50 ms, and closes one after 30 s without a
complete request.

## Commands the MkII app calls

| Command | Behaviour |
|---|---|
| `app_ready`, `app_control` | no-op (`'indicator start/stop'`, `'set_window_size:{"mode":"min","width":1160}'`) |
| `app_getevent` | pop one queued event, or `undefined` |
| `app_storage(data?)` | no argument: read the whole JSON (empty if missing); with an argument: write (`storage.json`) |
| `app_storage2(key, data?)` | per-key storage (`storage2/<key>`, percent-encoded); `data == ''` deletes; keys such as `ID_LIST`, `CONFIRM_FLAG`, `0`… |
| `app_importfile`, `app_exportfile` | no-op (cloud import/export) |
| `app_exit` | disconnect MIDI, close the window |
| `fs_separator` | `/` |
| `fs_path('temporary' \| 'library')` | absolute path **with a trailing `/`** |
| `fs_exec(url)` | open in the default browser — `http(s)://` only, never this Mac (Security, rule 6) |
| `fs_readString(path)`, `fs_writeString(path, text)` | permitted paths only (see Security) |
| `fs_openfilename('["tsl"]'?)` | asynchronous dialog → event `fs\fopenfilename\f<path>`, empty when cancelled; window only |
| `fs_savefilename(name, ext)` | asynchronous dialog, `name.ext` in its name field and `ext` as its file type, so the dialog adds the extension and asks before replacing that file → event `fs\fsavefilename\f<path>` (extension appended unless present); window only |
| `midi_inendpoints`, `midi_outendpoints` | JSON array of `{"MIDIEntityNameKey", "MIDIDeviceNameKey", "MIDIEndpointUIDKey"}`, all three the port name |
| `midi_inconnect(json)`, `midi_outconnect(json)` | open the listed port named by `MIDIEntityNameKey`; failure → event `midi\fconnectfailed\f<json>` |
| `midi_indisconnect`, `midi_outdisconnect` | close |
| `midi_send(HEX)` | hex without spaces → bytes → split into whole messages (sysex `F0…F7`) → Universal MIDI Packets → send; a message CoreMIDI fails to send is logged, not raised |
| `midi_panel` | no-op |

Behaviour worth knowing:

- Inputs and outputs are paired by an identical `MIDIEntityNameKey`, so input and output port names must match.
- The page remembers the chosen device by `MIDIEndpointUIDKey`; without one, every port matches. The port name serves as
  the UID (ADR-0005), so a device stored under 0.1.x is found again. Names are built as python-rtmidi built them for
  ports without connections drawn in Audio MIDI Setup (ADR-0011): the endpoint's name without surrounding spaces, else
  its entity's, with the device's name in front unless the name already starts with it. A name with non-ASCII characters
  is the exception: python-rtmidi decoded CoreMIDI's names as MacRoman (`encoding='auto'`), the app reads them as
  CoreMIDI holds them, so such a device goes through the device picker once.
- Ports whose names contain any of `<>&"'` are neither listed nor opened, since the page renders names as HTML.
- Incoming MIDI: event `midi\fmessage\f<HEX, uppercase, no spaces>\f<timestamp ms>`; one whole message per event,
  sysex reassembled across packets; MIDI time code quarter frames (`F1`), timing clock (`F8`) and active sensing (`FE`)
  are dropped, and so is a sysex longer than 1 MiB (with one log line; an All Data Backup is about 81 KB). CoreMIDI
  carries MIDI 1.0 as Universal MIDI Packets (sysex as SysEx7), converted to and from bytes in the app.
- Hot-plug: CoreMIDI's setup-changed notification → the port lists are compared → event `midi\fchanged` when they
  differ.
- The page sends its MIDI queue one message at a time, paced by its own interval.
- Closing the window: the shell sends the page `app\fcommand\fexit`; the page sends DT1 `7F 00 00 01 = 00` (editor
  communication mode off) and calls `$$app_exit` 500 ms later. The close button, Cmd-W, Cmd-Q and `SIGINT`/`SIGTERM` all
  go this way: closing is refused until then, the event is queued once and a 2 s fallback is armed. `$$app_exit`
  disconnects MIDI and closes the window, which quits the app.
- Storage and file reads return the text as stored; a file that is not UTF-8 is an error.
- The page's usage telemetry posts to `index.html` and, through the proxy, to Roland. As in 0.1.1, a POST to any path
  under the token other than `$$…` and `log`, whether a file is there or not, gets `204` and is forwarded nowhere.
- Tone Central fetches from `api.roland.com`, `bosstonecentral.com`, YouTube and SoundCloud, whose servers send no CORS
  headers; the proxy fetches the first three (see Security). SoundCloud's API rejects the page's old client ID, so its
  audio previews never worked and its requests are refused.

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

1. It listens on `127.0.0.1` only and needs exactly one `Host` header, equal to `127.0.0.1:P`, on every GET, HEAD and
   POST (DNS rebinding; a second one is a `400`, rule 8); `localhost` and `[::1]` are refused, and other methods get
   `501`.
2. Everything lives under a per-launch token (24 random bytes, URL-safe base64), compared in constant time: the page
   `/<token>/index.html`, its files, the commands `/<token>/$$…`, `/<token>/proxy` and `/<token>/log`. Any other path
   gets `403`, so the server never gives the token away; the window opens the page with it, and `--browser` prints that
   URL. Commands are POST only (GET → `405`), are named `$$<object>_<method>` in ASCII (`404` otherwise) and need
   `Content-Type: application/json` (`415` otherwise), which no cross-site form can send without a preflight. A POST
   under the token to anything but `$$…` or `log` is taken for the page's usage telemetry (to `index.html`, or to Roland
   through the proxy): it is dropped with `204` and reaches nothing.
3. A foreign `Origin` (anything but `http://127.0.0.1:P`) and any `Sec-Fetch-Site` outside {absent, `same-origin`,
   `none`} are rejected on every path under the token, the page under any spelling of its path (`/<token>/`,
   `/<token>/./index.html`, `/<token>/%69ndex.html`…) included. Static files are served only from inside the web app's
   folder, after resolving the path. Every response forbids framing (`X-Frame-Options: DENY`, `frame-ancestors
   'none'`) and content sniffing (`X-Content-Type-Options: nosniff`) and is not cached (`Cache-Control: no-store`), so
   other websites can neither drive the bridge nor open or frame the editor.
4. The page comes with a `Content-Security-Policy` header, its nonce new for every response (one directive per line
   here; the header separates them with `; `):

   ```text
   default-src 'self'
   script-src 'self' 'nonce-<nonce>' 'unsafe-eval' 'unsafe-hashes' 'sha256-<hash>' https://www.youtube.com
   style-src 'self' 'unsafe-inline'
   img-src 'self' https: data:
   frame-src https://www.youtube.com
   connect-src 'self'
   font-src 'self' data:
   object-src 'none'
   base-uri 'self'
   form-action 'none'
   frame-ancestors 'none'
   ```

   The nonce admits the bridge script; the hash is that of `return false`, Roland's one inline handler
   (`<body oncontextmenu="return false">`). Roland's knob and spinner controls and jQuery's script evaluation need
   `'unsafe-eval'`; the YouTube player needs its host. Other inline scripts, injected event handlers and `javascript:`
   URLs are blocked; a `<script>` in HTML that jQuery inserts still runs (ADR-0003, residual risks).
5. `fs_readString` reaches the app's data and temp folders, a file the user picked in the open dialog during this
   session, and a path picked in the save dialog; `fs_writeString` only the folders and save-dialog paths. Paths are
   compared resolved (`..` and links), and a path that does not exist yet is resolved through its nearest existing
   ancestor, so no link leads out of a folder; a dangling link at any level, and a NUL byte, are refused. The file is
   then read or written at the resolved path. The save dialog's extension must be 1–10 ASCII letters and digits, since
   it is appended to the picked path.
6. Only `http(s)` links to other machines leave for the default browser, since the page's own URLs carry the token;
   `fs_exec` and the window apply the same rule. Not passed on are links without a host or with userinfo, and links to
   `localhost` or `*.localhost`, to an IPv4 address in `127.0.0.0/8` or `0.0.0.0/8` in any spelling `inet_aton` accepts
   (`127.1`, `0x7f000001`, `2130706433`), or to `[::1]`, `[::]` or another IPv6 form of those addresses
   (`[::ffff:127.0.0.1]`); letter case, of the scheme too, and a trailing dot change nothing. `fs_exec` refuses such a
   link with an error. The window opens no new windows: a clicked link with a new target, or a `window.open` after a
   click, goes to the browser if the rule lets it and is dropped otherwise; `window.open` without a click does nothing.
   The window itself stays on `http://127.0.0.1:P`: a navigation anywhere else goes to the browser by the same rule or
   is dropped, and subframes load only `https` (the YouTube player) or `about:` URLs.
7. The proxy fetches GET requests only (POST → `204`), from `api.roland.com`, `bosstonecentral.com` and
   `www.youtube.com`. It rebuilds the URL from `https`, the host name, path and query, dropping userinfo, port and
   fragment, and holds every redirect to the same list and rebuilds it the same way; a refused URL or redirect → `403`,
   a failed fetch → `502`. A fetch times out after 20 s without data or 60 s in all, sends the User-Agent
   `Mozilla/5.0 (Macintosh)`, and neither sends nor keeps cookies. Answers from Roland's hosts pass only if they parse
   as JSON (`502` otherwise) and go out as `application/json` when Roland's server said JSON, else as `text/plain`, so
   jQuery never runs them as script or HTML (`.tsl` files come as `binary/octet-stream`, and the page parses them
   itself); an error status passes without its body. YouTube's answers pass unchanged.
8. Requests are parsed strictly: a head of at most 64 KB with CRLF line ends, a request target of visible ASCII (raw
   bytes from `0x80` up are refused; XHR percent-encodes them), no folded headers, no `Transfer-Encoding`, at most one
   `Host`, `Origin`, `Sec-Fetch-Site` and `Content-Type`, a `Content-Length` of digits only (repeated only with the same
   value), bodies up to 64 MB; anything else → `400`, and the connection closes. A head whose lines end in bare line
   feeds never completes: its connection is closed after 30 s without a complete request, or gets `400` once the head
   passes 64 KB. Command arguments must be a JSON array of strings (`400` otherwise). Page log lines (whose error
   locations are the page's URLs) and failed requests are logged with the token removed in any spelling and with control
   characters, bidirectional controls and line separators escaped; page log lines are then cut at 500 characters.

The unit tests (target `BossToneStudioCoreTests`, in `Tests/BossToneStudioCoreTests/`) cover each rule. Of the
window's part of rule 6, the link rule it shares with `fs_exec` is tested; the WebKit delegate that applies it lives in
the app and is checked by hand. The router's rules (1–3, and the request side of 8) run against a real loopback server
with a stand-in bridge.
