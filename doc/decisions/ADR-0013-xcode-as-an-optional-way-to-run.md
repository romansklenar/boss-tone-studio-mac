# ADR-0013: Xcode as an optional way to run the app

Status: accepted, 2026-10-30

## Context

Running the app from Xcode failed while an installed copy was open, since both took the lock on the same data folder.
A shared scheme can set `BTS_DATA_DIR`, but only to a fixed value. Xcode runs a package's executable from DerivedData
and expands no build settings in a package scheme: with `$(SRCROOT)` or `$(PROJECT_DIR)` as the custom working
directory the app still ran from DerivedData (checked with `lsof` on Xcode 27's run, while an absolute path was
honoured), and an absolute path holds on one Mac only.

## Decision

- Commit a shared `BossToneStudio` scheme with `BTS_DATA_DIR=tmp/xcode`. Xcode stays optional: building, testing and CI
  need only the Command Line Tools ([ADR-0012](ADR-0012-swift-toolchain-without-dependencies.md)).
- A bare executable takes a relative `BTS_DATA_DIR` or `BTS_HTML_DIR` from the checkout it was built from. A `.app` takes
  it from the working directory, since the checkout's path is baked in at build time and may not exist on that Mac.

## Consequences

- `make run` behaves as before, since it runs from the checkout. A bare executable started from another folder no longer
  follows that folder for a relative path.
- A leading `~` is not expanded, as before: a scheme should not use one.
- The data-folder lock no longer stops an Xcode run next to an installed copy. Both windows then talk to the amp and
  overwrite each other's edits, so the README says to quit the installed one first.
- Xcode's builds go to DerivedData, outside the repository's `.build`.
