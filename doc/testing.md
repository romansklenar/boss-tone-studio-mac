# Testing

## Automated

`make check` runs ruff and the unit tests (`tests/`), as CI does on every pull request and push to `main`. They cover
the bridge's security rules (over a real loopback server with a stand-in bridge), response encoding, storage, the close
flow, the proxy allowlist, MIDI message splitting, the Librarian import and its running-app guard.

## The bridge without an amp

`make browser` serves the app and prints its URL; open it in a browser. Without an amp the page shows "DEVICE NOT
FOUND" — the MIDI port list went through the bridge — and **OFFLINE MODE** opens the editor, Librarian and Tone
Central. The token is in `window.$$xhrport` of the served `index.html`; with it, `curl` can exercise commands, e.g.
`curl "http://localhost:<port>/<token>/\$\$app_storage"`. Without the token, with a foreign `Host` or `Origin`, or for
a path outside the app's folders, the bridge must answer `403` or refuse.

## With an amp

Run `make trace` (or the built app's executable with `BTS_TRACE=1`) and keep its output; every bridge command
(`-> $$…`) except the `$$app_getevent` poll and every incoming MIDI message (`<- midi.message`) is logged.

| Check | What the trace shows |
|---|---|
| The amp answers | `<- midi.message ['F07E000602413303000008000000F7', …]` — Identity Reply; the byte after `00 00` is the model (`08` HEAD, `09` ARTIST) |
| It connected | `-> $$midi_inconnect` / `$$midi_outconnect` with the `KATANA` port |
| Editor mode on | `-> $$midi_send ['F041…12 7F000001 01 …']` after connecting |
| Amp → app | `<- midi.message ['F041000000003312…']` when turning the amp's knobs |
| App → amp | `-> $$midi_send ['F041000000003312 60…']` when changing a value in the app (after the start-up burst) |
| Clean close | `<- app.command ['exit']`, `-> $$midi_send [… 7F000001 00 …]`, `-> $$app_exit`, exit code 0 |
| No errors | no `[js]`, `[bts] … failed` or `Traceback` lines |

Then try in the window: export a liveset to `.tsl` and import it back, an All Data Backup, deleting a patch and a
liveset (they must stay deleted after reopening). Record new amplifiers in the README's "Verified amplifiers".
