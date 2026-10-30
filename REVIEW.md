# Review instructions

Write every review comment and suggestion in English.

## What to flag

- **Roland's files:** a file of Roland's in the diff, such as anything from `build/roland/`, the web app's HTML/JS,
  the installer zip or the `.icns`. Also any change that patches Roland's files instead of adapting the page through
  the script injected into the served `index.html`.
- **Drift from the spec:** `doc/bridge-protocol.md` is the specification for `Sources/`. Flag a change to commands,
  answers, status codes, events or security rules that does not update that document in the same pull request, or
  that contradicts it. A new design decision needs an ADR in `doc/decisions/`.
- **Weaker security:** anything that loosens a rule in the protocol's Security section:
  - binding beyond `127.0.0.1`, or the `Host`, token, `Origin` or `Sec-Fetch-Site` checks;
  - the Content-Security-Policy, the proxy allowlist, or JSON-only answers from Roland's hosts;
  - the read and write sets for files, or the rule that sends only web links off this Mac to the browser;
  - logging the token or unescaped page input.
- **Missing tests:** a behaviour change in `Sources/BossToneStudioCore` without a Swift Testing test.
- **Broken data for existing users:** changes to the app name, bundle identifier, data folder, `storage.json` /
  `storage2/<key>` formats, MIDI port names (the page stores the name as the device ID) or the `[bts]`, `[trace]` and
  `[js]` log line shapes.
- **Toolchain:** a package dependency in `Package.swift`, an API newer than macOS 14 without an availability check, a
  deprecated API (warnings are errors), XCTest, or a test that creates a CoreMIDI client.
- **Concurrency:** shared mutable state outside `OSAllocatedUnfairLock`, blocking the main thread, or calling into the
  host, the MIDI controller or the MIDI backend (CoreMIDI) while holding a lock (ADR-0015).
- **Comments and docs:**
  - comments that say what the code does instead of why;
  - comments or docs that no longer match the code;
  - lines over 120 characters in Markdown;
  - personal names in documents (say what was checked by hand, not who checked it).

## What not to flag

- Formatting that `swift format` handles: `make lint` runs in CI.
- Suggestions to add third-party packages, to require Xcode (it is optional, ADR-0013), or to modify Roland's web app.
- That the built `.app` is ad-hoc signed and not notarized: this is deliberate (README, Licensing).
