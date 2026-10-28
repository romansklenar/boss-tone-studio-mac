# 0004 — Large writes over POST, arguments as strings

Status: accepted, 2026-10-28

## Context

An All Data Backup (~81 KB) and full livesets go to the bridge as GET arguments, and Python's `http.server` rejects
request lines over 64 KB with `414`, so backups silently failed.

## Decision

Replace `fs.writeString` and the write form of `app.storage2` with synchronous POSTs carrying a JSON array of
arguments, behind the same token and origin checks. The page script converts every argument to a string, matching
GET, and throws on any answer but HTTP 200.

## Consequences

- Backups and large livesets save. Converting to strings matters: the Librarian passes numeric liveset IDs, and
  without it deleting livesets and patches failed mid-way. A unit test guards it.
