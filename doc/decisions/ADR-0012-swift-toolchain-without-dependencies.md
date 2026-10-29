# ADR-0012: Apple's Swift toolchain, pinned to major version 6, and no dependencies

Status: accepted, 2026-10-29; supersedes [ADR-0009](ADR-0009-pinned-toolchain-with-mise.md)

## Context

ADR-0009 pinned Python, ruff and uv through mise and locked every package with hashes, because python-rtmidi was built
from source and the bundle shipped whatever `.venv` held. The native app
([ADR-0011](ADR-0011-native-swift-app.md)) uses only Apple's frameworks, so nothing is downloaded or locked; what is
left to pin is the compiler. Apple's Command Line Tools ship Swift (6.4 today), the macOS SDK, Swift Testing and
`swift format`, but neither Xcode nor XCTest. CI's macOS runner uses Xcode's Swift instead.

Pinning the exact toolchain through mise was tried and dropped: swift.org's macOS toolchain is 4.8 GB, and CI would
download it on every macOS run.

## Decision

- No package dependencies: Foundation, AppKit, WebKit, Network, CoreMIDI, UniformTypeIdentifiers, CryptoKit, Security
  and os (`OSAllocatedUnfairLock`) for the app; CoreGraphics and ImageIO for the icon script.
- Build and test with the Command Line Tools alone; `swift-tools-version: 6.0`, the Swift 6 language mode, and compiler
  warnings as errors on every build and test.
- Pin the major version only. `make swift-version`, a prerequisite of `setup`, `build`, `test`, `lint` and `app`,
  prints `Swift x.y.z` and stops on any major version but 6; any 6.x is fine.
- Work around [swiftlang/swift-build#1870](https://github.com/swiftlang/swift-build/issues/1870): the Command Line
  Tools' build system sometimes leaves Swift Testing's macro plugin out of the compiler call after a clean build. When
  `xcode-select -p` is the Command Line Tools, the Makefile passes that plugin's folder with `-plugin-path`.
- Format and lint with `swift format` from the toolchain, configured in `.swift-format` for 120-character lines.
- CI (`.github/workflows/ci.yml`): `make lint` on Ubuntu in the official `swift` container, pinned by digest to the
  minor version the code was last formatted with (swift-format's output can change between minors), whenever a pull
  request is opened, updated or marked ready, drafts included, and on every push to `main`. `make test` on macOS
  (`macos-26`, the runner's default Xcode) only for pull requests that are not drafts and for pushes to `main`:
  Network.framework, CoreMIDI and AppKit exist only on macOS, where minutes cost ten times as much. Actions stay
  pinned to commit SHAs, and a newer run cancels an older one.

## Consequences

- Setup needs only `xcode-select --install`; nothing is locked or downloaded besides Roland's installer.
- A Command Line Tools update can change the compiler's minor version under the project; `make check` shows whether
  that matters, and a release is still re-tested with an amp. Swift 7 stops the build with a clear message until the
  project moves.
- After a local minor update, `make format` and the lint container's tag and digest move together.
- Draft pull requests get no macOS test run, so `make check` runs locally before one is marked ready.
- The `-plugin-path` workaround comes out by hand once a Command Line Tools release has the upstream fix.
