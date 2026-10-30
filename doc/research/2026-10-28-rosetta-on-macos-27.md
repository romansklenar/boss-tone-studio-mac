# Rosetta on macOS 27 and beyond

Researched 2026-10-28, for: how long Roland's Intel-only MkII editor can keep running on Apple Silicon.

## Findings

- **Rosetta is fully supported through macOS 27.** Apple's enterprise release notes for macOS 27 say Rosetta remains a
  general-purpose compatibility tool through macOS 27 ([Apple, 148830](https://support.apple.com/en-us/148830)).
- **Upgrading to macOS 27.0 removed Rosetta.** The same notes say an installed Rosetta was not restored after
  upgrading to macOS 27; macOS 27.2 stops removing it on upgrade
  ([MacRumors, 2026-10-26](https://www.macrumors.com/2026/10/26/macos-27-2-stops-removing-rosetta/)).
- **From macOS 28 only a subset remains.** Following WWDC 2025, Apple's developer documentation said a limited subset
  of Rosetta stays after macOS 27, aimed at older, unmaintained games built on Intel frameworks
  ([MacRumors, 2025-06-10](https://www.macrumors.com/2025/06/10/apple-to-phase-out-rosetta-2/)). macOS 28 is expected in
  2027 (per the article, not Apple).
- Forum reports
  ([MacRumors forum](https://forums.macrumors.com/threads/macos-27-2-stops-upgrades-from-removing-rosetta.2492923/))
  mention having to reinstall Rosetta after the 27.0 upgrade; one claim that it reinstalls itself contradicts Apple's
  note. Anecdotes only.

## What it means here

On macOS 27.2 an Intel app can still run under Rosetta (reinstall it with `softwareupdate --install-rosetta` if the
27.0 upgrade removed it). From macOS 28, a device editor that talks to a USB amp is outside the announced subset, so
Roland's Intel-only MkII editor should be expected to stop running. This port has no Intel code, so the change does not
affect it.
