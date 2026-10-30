# ADR-0014: Events fetched in batches

Status: accepted, 2026-10-30

## Context

`native.js` polls every 50 ms and calls `$$app_getevent` until it answers `undefined`, one synchronous request per
event. A Librarian transfer brings hundreds of MIDI replies, so hundreds of requests. `native.js` can also take pushed
events (`app_startevent` and `$event.trigger`), but then it stops polling, and `--browser` mode has no window to push
from.

## Decision

- A new command, `$$app_getevents`, answers every queued event as a JSON array and empties the queue.
- The injected script defines `$$app.getevent` over a queue of its own: when that is empty it calls `$$app_getevents`
  once and hands the events out one by one, `undefined` when there are none. `native.js` and its polling are unchanged.
- `$$app_getevent` stays.

## Consequences

- A poll costs one request when nothing happened and two when something did, whatever the number of events.
- Events keep their order. A handler that throws ends `native.js`'s loop; the events after it wait in the script's queue
  for the next poll, as they waited in the bridge's before.
- The script's queue lives in the page: if the page reloads before that next poll, the events left in it are lost,
  where before they stayed in the bridge's queue.
- Pushed events remain possible later; they would need a polling fallback for `--browser` mode.
