# ADR-0015: The MIDI backend called from a serial queue, with no lock held

Status: accepted, 2026-10-30

## Context

In 1.0.0 the MIDI controller held an `OSAllocatedUnfairLock` across every connect, disconnect and send, so a send was
never interleaved with another send or a disconnect. CoreMIDI may report a setup change on any thread, also from inside
one of those calls. The controller's handler for it takes the same lock to compare the port lists, and that lock is not
reentrant: a report from inside a call would abort the app. REVIEW.md asks that no lock be held while calling out.

## Decision

- The controller runs every connect, disconnect and send on a serial `DispatchQueue` of its own, with `sync`: callers
  keep their synchronous answers, a failed connect is reported before the command returns, and a send has reached
  CoreMIDI before `$$midi_send` answers, so `$$app_exit` still follows the page's last send.
- The lock that remains guards plain state (the last port lists, whether an output is open) and is never held while
  the backend is called. The setup-changed handler takes only that lock and never waits for the queue.
- The `MidiBackend` contract: calls come one at a time from the controller's queue; an implementation may report a
  setup change or an incoming message from inside them, but must not call the controller's connects, disconnects or
  `send` from there, which would wait for the queue they run on.

## Consequences

- MIDI bytes, their order and the events the page sees are unchanged.
- A setup change reported from inside a backend call is handled; a fake backend that does so pins it in the tests.
- The CoreMIDI backend keeps its own short lock for its state and holds none across a CoreMIDI call.
