# AGENTS.md

Native arm64 shell for Roland's BOSS TONE STUDIO for KATANA MkII web app: a Python HTTP bridge speaking Roland's
`$native` protocol, CoreMIDI through python-rtmidi, a pywebview (WKWebView) window. Personal use; Roland's HTML is
never modified or committed — `make roland-assets` takes it out of Roland's installer download into `build/roland/`
and `make app` bundles it.

Start with [`doc/plans/2026-10-27-reimplementation-handover.md`](doc/plans/2026-10-27-reimplementation-handover.md):
the protocol (source of truth), the user's decisions, security rules, environment traps and status.

## Commands

```bash
make setup          # mise install (pinned Python/ruff/uv) + uv pip sync requirements.txt + make roland-assets
make lock           # re-resolve requirements*.txt after changing pins in pyproject.toml
make run | browser | trace | import-roland
make app | install  # standalone .app (PyInstaller) → dist/, then ~/Applications
make test           # python -m unittest discover -s tests -t .
make lint | format  # ruff
make check          # lint + test — run before committing
```

## Conventions

- Code, comments, docs and commit messages in English; talk to the user in Czech.
- Conventional Commits with a capital letter (`Feat:`, `Fix:`, `Docs:`, `Chore:`), never amend, trailer
  `Co-authored-by: Claude <noreply@anthropic.com>`.
- 120-character lines (ruff). Lean comments: say why, not what.
- Plans and findings go to `doc/plans/YYYY-MM-DD-<topic>.md`.
- Never write to Roland's app or its plist; scratch work and personal backups go to `tmp/` (gitignored).
- Claim only what was verified; say how (curl, browser pane, `make trace` log, the user in the window).

## Sandbox notes

MIDI (CoreMIDI client), writes to `~/Library` and building python-rtmidi only work outside the Claude Code sandbox;
run the app with `BTS_DATA_DIR=$PWD/tmp/<name>` while testing. Details: §6 of the handover document.
