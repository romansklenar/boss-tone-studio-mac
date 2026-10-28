# 0008 — A standalone app bundle built from Roland's installer download

Status: accepted, 2026-10-28

## Context

Reading the web app from Roland's installed app meant keeping an Intel app (and Rosetta) around. Roland's own macOS
installer zip holds the same web app, and its package can be expanded without installing anything. Roland's licence
forbids redistributing its software.

## Decision

- `make roland-assets` downloads Roland's installer from Roland's server, checks a pinned SHA-256, expands the package
  with `pkgutil --expand-full` and keeps the web app, the icon and the zip (as the backup copy) in `build/roland/`.
- `make app` bundles the web app with PyInstaller (py2app cannot handle mise's python-build-standalone interpreter);
  at runtime the bundled copy is used unless `BTS_HTML_DIR` overrides it.
- The app is named "BOSS TONE STUDIO for KATANA MkII (Apple Silicon)" and its icon is Roland's on a slate-grey
  background, to tell it from Roland's app.
- Native code targets macOS 14 (`MACOSX_DEPLOYMENT_TARGET`), so the bundle should run on macOS 14–27 (tested on 27.2
  only).
- Nothing of Roland's is committed; the built app is for the builder's own use and is not distributed.

## Consequences

- No Intel binary is needed anywhere; Roland's app can be uninstalled.
- New builds depend on Roland's download staying up; the kept zip covers rebuilds.
- Distributing a ready-made app would need a version that fetches Roland's web app on first launch, plus its own name,
  icon and notarization.
