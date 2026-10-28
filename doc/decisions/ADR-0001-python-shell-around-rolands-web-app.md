# ADR-0001: A Python shell around Roland's unchanged web app

Status: accepted, 2026-10-27

## Context

Roland's MkII editor is an HTML/JS web app inside a thin Intel-only native shell. Three ways to get it onto Apple
Silicon were weighed: keep using Rosetta (no work, but on its way out), a Python shell (pywebview + python-rtmidi), or a
native Swift/Objective-C shell (WKWebView + embedded HTTP server + CoreMIDI).

## Decision

Build the Python shell first as the proof of concept: pywebview (Cocoa/WKWebView) for the window, python-rtmidi for
CoreMIDI, the standard library's HTTP server for the bridge. Roland's web app runs unchanged.

## Consequences

- Fast to build and to change; everything is in a few hundred lines of Python.
- The bundle (~38 MB) carries its own Python and is ad-hoc signed.
- A native rewrite remains possible later; the bridge protocol (`doc/bridge-protocol.md`) is what it must implement.
