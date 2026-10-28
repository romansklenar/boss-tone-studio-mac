"""CoreMIDI access (via python-rtmidi) in the shape Roland's `$native.midi` expects."""

import json
import threading
import time

import rtmidi

# Data-byte count for channel-voice status nibbles and system-common statuses.
_CHANNEL_LENGTHS = {0x80: 2, 0x90: 2, 0xA0: 2, 0xB0: 2, 0xC0: 1, 0xD0: 1, 0xE0: 2}
_SYSTEM_LENGTHS = {0xF1: 1, 0xF2: 2, 0xF3: 1}


def split_messages(data):
    """Splits a byte stream into complete MIDI messages, so each goes to CoreMIDI as one packet."""
    messages, i = [], 0
    while i < len(data):
        status = data[i]
        if status < 0x80:  # a stray data byte without a status: nothing to send it with
            i += 1
            continue
        if status == 0xF0:
            end = data.find(0xF7, i)
            end = len(data) - 1 if end < 0 else end
        elif status >= 0xF0:
            end = i + _SYSTEM_LENGTHS.get(status, 0)
        else:
            end = i + _CHANNEL_LENGTHS.get(status & 0xF0, 0)
        messages.append(data[i : end + 1])
        i = end + 1
    return messages


def endpoint(name):
    # The name doubles as the UID the page remembers the device by (doc/decisions/0005).
    return {"MIDIEntityNameKey": name, "MIDIDeviceNameKey": name, "MIDIEndpointUIDKey": name}


class Midi:
    def __init__(self, emit):
        self._emit = emit
        self._lock = threading.Lock()
        self._probe_in = rtmidi.MidiIn()
        self._probe_out = rtmidi.MidiOut()
        self._input = None
        self._output = None
        self._ports = self._port_names()
        threading.Thread(target=self._watch_ports, daemon=True).start()

    def inputs(self):
        return json.dumps([endpoint(n) for n in self._probe_in.get_ports()])

    def outputs(self):
        return json.dumps([endpoint(n) for n in self._probe_out.get_ports()])

    def connect_input(self, ep_json):
        self.disconnect_input()
        port = self._open(rtmidi.MidiIn(), ep_json)
        if port:
            port.ignore_types(sysex=False, timing=True, active_sense=True)
            port.set_callback(self._on_message)
            with self._lock:
                self._input = port

    def connect_output(self, ep_json):
        self.disconnect_output()
        port = self._open(rtmidi.MidiOut(), ep_json)
        with self._lock:
            self._output = port

    def disconnect_input(self, *_):
        with self._lock:
            port, self._input = self._input, None
        if port:
            port.cancel_callback()
            port.close_port()

    def disconnect_output(self, *_):
        with self._lock:
            port, self._output = self._output, None
        if port:
            port.close_port()

    def disconnect_all(self):
        self.disconnect_input()
        self.disconnect_output()

    def send(self, hex_msg):
        with self._lock:
            if not self._output:
                return
            for message in split_messages(bytes.fromhex(hex_msg)):
                self._output.send_message(message)

    def _open(self, port, ep_json):
        name = json.loads(ep_json).get("MIDIEntityNameKey") if ep_json else None
        ports = port.get_ports()
        if name not in ports:
            self._emit("midi", "connectfailed", ep_json or "")
            return None
        port.open_port(ports.index(name))
        return port

    def _on_message(self, event, _data):
        message, _delta = event
        self._emit("midi", "message", bytes(message).hex().upper(), str(int(time.time() * 1000)))

    def _port_names(self):
        return (tuple(self._probe_in.get_ports()), tuple(self._probe_out.get_ports()))

    def _watch_ports(self):
        while True:
            time.sleep(1.5)
            try:
                ports = self._port_names()
            except Exception as error:  # a transient CoreMIDI failure must not end hot-plug detection
                print(f"[bts] listing MIDI ports failed: {error!r}")
                continue
            if ports != self._ports:
                self._ports = ports
                self._emit("midi", "changed")
