# AGENTS.md

Native arm64 shell for Roland's BOSS TONE STUDIO for KATANA MkII web app, written in Swift with no dependencies: an
HTTP bridge on `127.0.0.1` speaking Roland's `$native` protocol, CoreMIDI, an AppKit window with a WKWebView. Personal
use; Roland's HTML is never modified or committed — `make roland-assets` takes it out of Roland's installer download
into `build/roland/` and `make app` bundles it.

Start with [`doc/bridge-protocol.md`](doc/bridge-protocol.md) (the protocol and security rules — the source of truth
for `Sources/`), then [`doc/decisions/`](doc/decisions/), [`doc/design/`](doc/design/) and [`doc/plans/`](doc/plans/)
(each release's design and how its work ran) and [`doc/research/`](doc/research/); status and verified amps are in the
README.

## Commands

```bash
make help           # every target
make setup          # make swift-version (fails unless Swift 6) + make roland-assets
make check          # lint (swift format) + test (swift test) — run before committing; CI runs the same
make app            # the signed .app in dist/, Roland's web app re-extracted from the verified zip
make release-notes VERSION=x.y.z   # a GitHub Release body in tmp/ (see Releases)
```

## Workflow

- `main` only moves through reviewed pull requests; work happens on feature branches (`feat/…`, `fix/…`, `refactor/…`,
  `docs/…`).
- What a code review flags and skips is in [`REVIEW.md`](REVIEW.md); follow it when reviewing a pull request.
- CI (`.github/workflows/ci.yml`) runs `make lint` on Ubuntu in a digest-pinned Swift container for every pull request,
  drafts included, and `make test` on macOS 26 only for pull requests ready for review; both run on pushes to `main`.
  The test job switches to the Command Line Tools first. Actions are pinned to commit SHAs. After a local Swift minor
  update, run `make format` and bump the container's tag and digest together.
- Push only `main` and feature branches — never `--all`/`--mirror`, and never a local `archive/*` branch.

## Releases

- Semantic Versioning. The version lives only in `VERSION`; `make app` copies it into the bundle's `Info.plist`.
- A release collects the pull requests merged since the last tag. Those leave `VERSION` and `CHANGELOG.md` alone; a
  release pull request of its own bumps the version and adds a dated entry for all of them to `CHANGELOG.md` (no
  Unreleased section). After its merge, tag that `main` commit with an annotated tag (`git tag -a vX.Y.Z -m vX.Y.Z`)
  and push it; fix the date in the PR if the merge slips to another day.
- Then publish a GitHub Release, without assets — never attach the built `.app`, it contains Roland's files:
  `make release-notes VERSION=x.y.z` writes its body (the version's changelog section with wrapped lines joined, then
  GitHub's generated notes) to `tmp/`, and `gh release create vX.Y.Z --verify-tag --title vX.Y.Z --notes-file <it>`
  publishes it.

## Conventions

- Code, comments, docs and commit messages in English.
- Conventional Commits with a capital letter and a scope when one area fits (`Feat:`, `Fix(router):`, `Refactor(midi):`,
  `Test:`, `Docs:`, `Chore:`), never amend.
- 120-character lines (`swift format`, `.swift-format`). Lean comments: say why, not what.
- A new design decision gets a record in `doc/decisions/ADR-NNNN-<title>.md`, cited as `ADR-NNNN` (context, decision,
  consequences); research findings go to `doc/research/YYYY-MM-DD-<topic>.md`.
- Never write to Roland's app or its plist; scratch work and personal backups go to `tmp/` (gitignored).
- Builds take hundreds of MB: build only into the repo's `.build` (no extra `--scratch-path` builds or copies of it),
  delete any scratch build you make, and run `make clean` when a piece of work is finished.
- Claim only what was verified; say how (curl, browser pane, `make trace` log, the user in the window).

## Sandbox notes

- `swift` and `xcrun` keep caches outside the project, which the Claude Code sandbox cannot write: run `make setup`,
  `make build`, `make test`, `make check`, `make app` and `make run`/`browser`/`trace` with the sandbox off.
- The sandbox cannot create a CoreMIDI client (`MIDIClientCreateWithBlock failed (OSStatus -10833)`) nor the app's
  temp folder, so the app only runs outside it. The unit tests never create a MIDI client. Run the app with
  `BTS_DATA_DIR=$PWD/tmp/<name>` instead of the real data folder.
- `$TMPDIR` differs inside and outside the sandbox; write logs to the project's `tmp/`.
- `open`/`osascript` and `ps`/`pgrep` fail inside the sandbox; check processes outside it (`ps`, `lsof -iTCP`).
- The server answers only `http://127.0.0.1:<port>/<token>/…` (`localhost` is refused): open the URL `make browser`
  prints in the browser pane for visual checks. The native window cannot be seen — verify it through `make trace`
  logs and written storage.
