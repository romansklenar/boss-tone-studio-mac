# ADR-0010: `native.js`'s `$$app` hook as the only transport

Status: accepted, 2026-10-28; supersedes [ADR-0004](ADR-0004-post-for-large-writes.md) and the transport part of
[ADR-0002](ADR-0002-local-http-bridge-speaking-native-js.md)

## Context

The bridge used `native.js`'s URL transport. That needed a forged `roland.quattro` user agent and a `$$xhrport` holding
the token. It also needed three overrides on top of it:
- `midi.send`, which goes through a WebKit handler only Roland's shell registers;
- `fs.writeString` and the write form of `app.storage2`, whose large values outgrow a GET URL.

The result was two transports (GET with typed answers, POST with JSON) and arguments parsed from the URL path.
`native.js` checks first for `window.$$app`, and when it exists calls `window['$$' + object][method](args…)` and uses
the result as is.

## Decision

Inject one script before `native.js` that defines `$$app`, `$$midi`, `$$fs` and the other objects `native.js` can
call. Each is a `Proxy` that sends every call as a synchronous `POST /<token>/$$<command>` with a JSON array of string
arguments and returns the JSON-decoded answer, throwing on any status but 200. It leaves `startevent` undefined, so
events are still polled. The bridge accepts commands only this way.

## Consequences

- One code path for every command. The user-agent override, `$$xhrport`, the `midi.send`/`fs.writeString`/`storage2`
  overrides, URL argument parsing and the typed answer encoding are gone.
- Commands need `Content-Type: application/json`, which a cross-site form cannot send. This adds a CSRF barrier on top
  of the token and origin checks. The token is no longer a page-wide global.
- `curl` checks must POST JSON (see `doc/testing.md`).
- Pushed events (`startevent` with `$event.trigger`) remain possible later, but only in the window: `--browser` mode
  has no way to call into the page.
