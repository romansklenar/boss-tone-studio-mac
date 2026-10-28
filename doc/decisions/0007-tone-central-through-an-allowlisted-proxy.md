# 0007 — Tone Central through an allowlisted proxy

Status: accepted, 2026-10-28

## Context

Tone Central's servers (`api.roland.com`, `bosstonecentral.com`) were still live but send no CORS headers, so the page
could not load them from `localhost`. The alternative was hiding Tone Central.

## Decision

Rewrite the page's absolute `$.ajax` URLs to a token-guarded `/__proxy` endpoint that fetches over HTTPS from an
allowlist of Tone Central's hosts only, checks redirects against it, and drops POSTs (usage telemetry).

## Consequences

- The catalogue, details, YouTube previews and adding livesets work; SoundCloud previews do not (its API rejects the
  page's old key).
- The proxy cannot be used to reach other hosts. It depends on Roland keeping those services up.
