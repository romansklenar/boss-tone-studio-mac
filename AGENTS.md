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
make help           # every target
mise trust          # once, by the user: mise.toml sets environment variables
make setup          # make deps (toolchain + locked packages into .venv) + make roland-assets
make lock           # re-resolve requirements*.txt (with hashes) after changing pins in pyproject.toml
make check          # lint + test — run before committing; CI runs the same on PRs and main
```

## Workflow

- `main` only moves through reviewed pull requests; work happens on feature branches (`feat/…`, `fix/…`, `docs/…`).
- CI (`.github/workflows/ci.yml`) runs `make lint` on Ubuntu and `make deps` + `make test` on macOS 15 (Apple
  Silicon) for every pull request and push to `main`; actions are pinned to commit SHAs.
- Push only `main` and feature branches — never `--all`/`--mirror`, and never a local `archive/*` branch.

## Releases

- Semantic Versioning. The version lives only in `pyproject.toml`; `make app` copies it into the bundle's
  `Info.plist`.
- A pull request with a user-visible change is its own release: it bumps the version and adds a dated entry for it to
  `CHANGELOG.md` (no Unreleased section). After the merge, tag that `main` commit with an annotated tag
  (`git tag -a vX.Y.Z -m vX.Y.Z`) and push it; fix the date in the PR if the merge slips to another day.
- A GitHub Release carries the changelog notes only. Never attach the built `.app`: it contains Roland's files.

## Conventions

- Code, comments, docs and commit messages in English; talk to the user in Czech.
- Conventional Commits with a capital letter (`Feat:`, `Fix:`, `Docs:`, `Chore:`), never amend.
- 120-character lines (ruff). Lean comments: say why, not what.
- A new design decision gets a record in `doc/decisions/ADR-NNNN-<title>.md`, cited as `ADR-NNNN` (context, decision,
  consequences); research findings go to `doc/research/YYYY-MM-DD-<topic>.md`.
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
