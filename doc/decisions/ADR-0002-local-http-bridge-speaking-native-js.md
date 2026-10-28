# ADR-0002: A local HTTP bridge speaking `native.js`'s own protocol

Status: accepted, 2026-10-27

## Context

The web app reaches its native shell through `js/lib/native.js`, which already has a Mac transport: synchronous GETs
to `http://localhost:$$xhrport/$$command;args`, enabled by a `roland.quattro` user agent. Patching Roland's files would
be fragile and would modify Roland's software.

## Decision

Serve Roland's files unchanged from a local HTTP server and implement that protocol. Configure the page by adding two
`<script>` blocks to the `index.html` response only: `$$xhrport`, the user agent, and replacements for the calls that go
through WebKit message handlers only Roland's shell registers (`midi.send`) or outgrow a URL (large writes); later also
a JS error hook and the Tone Central prefilter ([ADR-0007](ADR-0007-tone-central-through-an-allowlisted-proxy.md)).
Parse arguments from the raw request path.

## Consequences

- No file of Roland's is modified on disk; the injection is visible in one place (`bts/server.py`).
- Only the commands the MkII app calls are implemented; others answer "undefined" and are logged.
- The page depends on synchronous XHR, which browsers deprecate — a long-term risk.
