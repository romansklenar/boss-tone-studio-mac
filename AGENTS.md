# AGENTS.md

Native arm64 shell for Roland's BOSS TONE STUDIO for KATANA MkII web app: a Python HTTP bridge speaking Roland's
`$native` protocol, CoreMIDI through python-rtmidi, a pywebview (WKWebView) window. Personal use; Roland's HTML is
never modified or committed — `make roland-assets` takes it out of Roland's installer download into `build/roland/`
and `make app` bundles it.

Start with [`doc/bridge-protocol.md`](doc/bridge-protocol.md) (the protocol and security rules — the source of truth
for `bts/`), then [`doc/decisions/`](doc/decisions/) and [`doc/research/`](doc/research/); status and verified amps are
in the README.

## Commands

```bash
make setup          # make deps (pinned Python/ruff/uv + requirements.txt into .venv) + make roland-assets
make lock           # re-resolve requirements*.txt after changing pins in pyproject.toml
make run | browser | trace | import-roland
make app | install  # standalone .app (PyInstaller) → dist/, then ~/Applications
make test           # python -m unittest discover -s tests -t .
make lint | format  # ruff
make check          # lint + test — run before committing; CI runs the same on every PR
```

## Workflow

- `main` only moves through reviewed pull requests; work happens on feature branches (`feat/…`, `fix/…`, `docs/…`).
- CI (`.github/workflows/ci.yml`) runs `make lint` on Ubuntu and `make deps` + `make test` on macOS 15 (Apple
  Silicon) for every pull request; actions are pinned to commit SHAs.
- Push only `main` and feature branches — never `--all`/`--mirror`, and never a local `archive/*` branch.

## Conventions

- Code, comments, docs and commit messages in English; talk to the user in Czech.
- Conventional Commits with a capital letter (`Feat:`, `Fix:`, `Docs:`, `Chore:`), never amend, trailer
  `Co-authored-by: Claude <noreply@anthropic.com>`.
- 120-character lines (ruff). Lean comments: say why, not what.
- A new design decision gets a record in `doc/decisions/NNNN-<title>.md` (context, decision, consequences); research
  findings go to `doc/research/YYYY-MM-DD-<topic>.md`.
- Never write to Roland's app or its plist; scratch work and personal backups go to `tmp/` (gitignored).
- Claim only what was verified; say how (curl, browser pane, `make trace` log, the user in the window).

## Sandbox notes

- The Claude Code sandbox cannot create a CoreMIDI client (`RtMidiError … -10833`) — anything touching MIDI, and
  running the app, needs the sandbox off. Test with `BTS_DATA_DIR=$PWD/tmp/<name>` instead of the real data folder.
- python-rtmidi builds from source (no cp313 arm64 wheel) and needs `xcrun`, which cannot write its cache inside the
  sandbox: run `make setup` / `make app` outside it. Inside, `UV_CACHE_DIR=$TMPDIR/uv-cache` avoids `~/.cache`.
- `$TMPDIR` differs inside and outside the sandbox; write logs to the project's `tmp/`.
- `open`/`osascript` and `ps`/`pgrep` fail inside the sandbox; check processes outside it (`ps`, `lsof -iTCP`).
- The browser pane reaches `http://localhost:<port>` (`make browser`) for visual checks; the native window cannot be
  seen — verify it through `make trace` logs and written storage.
