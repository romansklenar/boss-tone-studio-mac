# ADR-0005: The MIDI port name doubles as the endpoint UID

Status: accepted, 2026-10-28

## Context

The page remembers the chosen amp by `MIDIEndpointUIDKey`. python-rtmidi exposes port names but no CoreMIDI unique ID;
without a UID every port matched, so the app reconnected to whichever port came first.

## Decision

Report the port name as `MIDIEndpointUIDKey` (and as the entity and device names).

## Consequences

- The app reconnects to the amp the user picked. Two amps with the same port name (`KATANA`) cannot be told apart, so
  one amp is connected at a time.
- The native app ([ADR-0011](ADR-0011-native-swift-app.md)) calls CoreMIDI directly and could report real unique IDs,
  but keeps the name, built as rtmidi built it for ports without connections drawn in Audio MIDI Setup: the page
  stored that name as the device's UID, and a different one would send 0.1.x users back to the device picker.
