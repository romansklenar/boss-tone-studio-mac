# Testing

## Automated

`make check` runs `swift format lint --strict` and the unit tests (`swift test`, Swift Testing, with compiler warnings
as errors), as CI does (lint on every pull request, tests once it is ready for review, both on pushes to `main`). The
tests live in the `BossToneStudioCoreTests` target (`Tests/BossToneStudioCoreTests/`) and cover the library: the
bridge's security rules (over a real loopback server with a stand-in bridge), the HTTP parser and responses, the page
script and its policy, storage, file access, the close flow, the proxy, MIDI message splitting and Universal MIDI
Packets, the MIDI controller over a stand-in backend, the Librarian import and the data-folder lock. They never create
a CoreMIDI client. The window and the CoreMIDI backend are checked by hand, below.

## The bridge without an amp

`make browser` serves the app and prints its URL, `http://127.0.0.1:<port>/<token>/index.html`; open it in a browser
(`localhost` is refused). Without an amp the page shows "DEVICE NOT FOUND" — the MIDI port list went through the
bridge — and **OFFLINE MODE** opens the editor, Librarian and Tone Central. File dialogs need the app window. With the
token from the URL, `curl` can exercise commands:

```bash
curl -X POST -H 'Content-Type: application/json' -d '["ID_LIST"]' "http://127.0.0.1:<port>/<token>/\$\$app_storage2"
```

Without the token, with a foreign `Host` or `Origin`, or for a path outside the app's folders, the bridge must answer
`403` or refuse.

## With an amp

Run `make trace` (or the built app's executable with `BTS_TRACE=1`, which also enables the Web Inspector) and keep its
output; every bridge command (`-> $$…`) except the `$$app_getevent` poll and every incoming MIDI message
(`<- midi.message`) is logged.

| Check | What the trace shows |
|---|---|
| The amp answers | `<- midi.message ['F07E000602413303000008000000F7', …]` — Identity Reply; the byte after `00 00` is the model (`08` HEAD, `09` ARTIST) |
| It connected | `-> $$midi_inconnect` / `$$midi_outconnect` with the `KATANA` port |
| Editor mode on | `-> $$midi_send ['F041…12 7F000001 01 …']` after connecting |
| Amp → app | `<- midi.message ['F041000000003312…']` when turning the amp's knobs |
| App → amp | `-> $$midi_send ['F041000000003312 60…']` when changing a value in the app (after the start-up burst) |
| Clean close | `<- app.command ['exit']`, `-> $$midi_send [… 7F000001 00 …]`, `-> $$app_exit`, exit code 0 |
| No errors | no `[js]` or `[bts] … failed` lines |

Then try in the window: export a liveset to `.tsl` and import it back, an All Data Backup, deleting a patch and a
liveset (they must stay deleted after reopening), Tone Central, and closing with Cmd-Q, Cmd-W and the close button; any
`alert()` of the page shows as a sheet — import a `.tsl` whose JSON lacks the page's header (any `{"name":"x"}` file
named `*.tsl`) to trigger one. Check that a web link opens in the default browser and that nothing opens a new window;
with `BTS_TRACE=1`, `location.href = 'http://localhost:' + location.port + '/'` in the Web Inspector's console must open
nothing. Unplug and replug the amp: it must reconnect (the trace shows `midi.changed` and a new Identity Reply). End the
page's process, `BossToneStudio Web Content` under `make trace` (in Activity Monitor, or `kill` the `pid =` that
`lsappinfo list | grep -A12 '"BossToneStudio Web Content"'` prints): the trace shows `[bts] the web page's process
ended; reloading`, then the page's start-up commands, and the amp connects again. Record new amplifiers in the README's
"Verified amplifiers".
