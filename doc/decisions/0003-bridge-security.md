# 0003 — Lock the bridge to this page and these files

Status: accepted, 2026-10-27 (from a security review)

## Context

The bridge reads and writes files and opens URLs. Any web page open in the user's browser could otherwise call it on
`localhost`, and DNS rebinding could reach it under another host name.

## Decision

Listen on loopback only; check `Host` on every request; require a per-launch secret token as a path prefix (carried in
`$$xhrport`, so `native.js` adds it by itself); reject foreign `Origin`/`Sec-Fetch-Site` and forbid framing, so no
other website can open the editor either; limit file access to the app's folders and paths picked in a file dialog;
let `fs.exec` open `http(s)` links only. The rules are listed in `doc/bridge-protocol.md`.

## Consequences

- Other websites cannot drive the bridge; tests cover the token and request handling.
- Any local program that is not a browser — including other user accounts and sandboxed apps — can read the token
  from `index.html`. It then reaches the amp, the Librarian, the files picked this session, file dialogs and
  web links, but nothing else.

## Known weak points

From a security review on 2026-10-28; none is exploitable without code already on the Mac or in the page.

| Weak point | Follow-up |
|---|---|
| The token is served to any local client (above) | Open `/<token>/index.html` from the shell and refuse the bare page |
| Proxied scripts (YouTube, SoundCloud, Roland) and Tone Central titles, which the page renders as HTML, run with the token | Drop SoundCloud from the allowlist; a CSP for `index.html`; JSON-only for the Roland hosts |
| CoreMIDI port names are rendered as HTML, and any process can name a virtual port | Skip ports whose names contain `<>&"'` |
| pywebview opens `target=_blank` links of any scheme in the browser | `OPEN_EXTERNAL_LINKS_IN_BROWSER = False`; keep navigation on `localhost:P` |
| A file picked to open may also be written | Separate read and write sets; only save-dialog paths are writable |
| `::1` may stay unbound, so a local squatter could serve its own page there | Fail closed when `::1` cannot be bound |
| `make app` bundles `build/roland/html` without re-checking it against the verified zip | Re-extract from the zip on every `make app` |
| The bundle is unsigned, with no hardened runtime | Ad-hoc sign with `--options runtime`; verify in `make install` |
