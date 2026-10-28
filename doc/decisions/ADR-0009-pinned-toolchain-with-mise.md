# ADR-0009: Pinned toolchain and dependencies

Status: accepted, 2026-10-28

## Context

python-rtmidi builds from source on Python 3.13, and the app bundles whatever is in `.venv`, so drifting versions
change the shipped app.

## Decision

Pin Python, ruff and uv in `mise.toml`; pin direct dependencies exactly in `pyproject.toml` and lock all of them in
`requirements.txt` (runtime) and `requirements-app.txt` (adds PyInstaller and Pillow for the bundle), both via
`make lock`. The `Makefile` wraps setup, run, test, lint, format and build.

## Consequences

- Every setup builds the same app; updating means changing a pin, `make lock`, and re-testing with the amp.
