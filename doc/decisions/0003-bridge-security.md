# 0003 — Lock the bridge to this page and these files

Status: accepted, 2026-10-27 (from a security review)

## Context

The bridge reads and writes files and opens URLs. Any web page open in the user's browser could otherwise call it on
`localhost`, and DNS rebinding could reach it under another host name.

## Decision

Listen on loopback only; check `Host` on every request; require a per-launch secret token as a path prefix (carried in
`$$xhrport`, so `native.js` adds it by itself); reject foreign `Origin`/`Sec-Fetch-Site`; limit file access to the
app's folders and paths picked in a file dialog; let `fs.exec` open `http(s)` links only.

## Consequences

- Other websites cannot drive the bridge; tests cover the token and request handling.
- Programs already running as the user could read the token from `index.html`, but they have the user's access anyway.
