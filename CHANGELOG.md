# Changelog

Notable changes per release. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-28

First release.

### Added

- Native arm64 shell running Roland's unchanged BOSS TONE STUDIO for KATANA MkII 2.1.0 web app. It needs no Rosetta
  and no installed copy of Roland's app.
- A local HTTP bridge for Roland's `native.js` protocol, covering storage, files, CoreMIDI through python-rtmidi, and
  events. The bridge is locked to the served page by a per-launch token, Host and Origin checks, and a file allowlist.
- Takes over Roland's Librarian on the first launch; `make roland-import` repeats the import.
- Tone Central through an HTTPS proxy limited to an allowlist of hosts.
- A standalone `.app` built from Roland's installer download, checked against a pinned SHA-256.
- Verified with a KATANA-HEAD MkII and a KATANA-ARTIST MkII on macOS 27.2.

[Unreleased]: https://github.com/romansklenar/boss-tone-studio-mac/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/romansklenar/boss-tone-studio-mac/releases/tag/v0.1.0
