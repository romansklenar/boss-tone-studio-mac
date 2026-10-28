# ADR-0006: Take over Roland's Librarian on the first launch

Status: accepted, 2026-10-28

## Context

Owners of Roland's app have their livesets in Roland's NSUserDefaults plist, under the same keys the page uses. The
port keeps its own data folder, so without an import a former user starts with an empty Librarian.

## Decision

Before the page first loads, copy Roland's livesets, `ID_LIST` order and `CONFIRM_FLAG` verbatim into the port's
storage, reading the plist only. Run once (a marker file); `make import-roland` repeats it, skipping livesets already
present by content and moving colliding IDs to free ones within the limit of 50. Do not copy `pref` (MIDI device
choice).

## Consequences

- Former users open straight into their library; Roland's file is never written.
- Livesets created later in Roland's app need `make import-roland`, which refuses to run while the app is open (its
  in-memory Librarian would overwrite the import); an exclusive lock on the data folder enforces this and keeps a second
  app off it too. Storage writes are atomic, so a crash cannot truncate `ID_LIST`.
