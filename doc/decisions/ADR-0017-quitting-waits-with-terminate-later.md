# ADR-0017: Quitting waits for the page with `.terminateLater`

Status: accepted, 2026-10-30

## Context

A quit goes through the close handshake: the page takes the amp out of editor mode and then calls `$$app_exit`, or a
2 s fallback ends the wait. In 1.0.0 the app delegate answered `.terminateCancel` meanwhile, so a logout, restart or
shutdown was cancelled ("BOSS TONE STUDIO cancelled logout") instead of waiting for the app.

## Decision

- `applicationShouldTerminate` answers `.terminateNow` when the bridge lets the window close at once, else
  `.terminateLater`, and remembers that a reply is owed.
- When the window closes after the handshake (the page's `$$app_exit` or the fallback), the delegate replies
  `NSApp.reply(toApplicationShouldTerminate: true)`. A second quit while the page answers starts no second handshake.
- Cmd-W and the close button keep going through `windowShouldClose`; closing the window still quits the app.

## Consequences

- Cmd-Q, `SIGINT`/`SIGTERM`, the Dock, AppleScript and logout wait for the page instead of being cancelled; the
  fallback still bounds the wait.
- AppKit runs the run loop in modal panel mode while a reply is owed; the bridge's hops to the main thread use the main
  queue, which that mode serves.
- The delegate lives in the executable, which has no unit tests: the quit is checked by hand in the window
  (`doc/testing.md`).
