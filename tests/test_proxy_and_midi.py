import unittest
import urllib.request
from unittest import mock

from bts.midi import Midi, split_messages
from bts.proxy import _AllowlistedRedirects, checked_url


class CheckedUrlTest(unittest.TestCase):
    def test_tone_central_hosts_are_fetched_over_https(self):
        self.assertEqual(
            checked_url("http://api.roland.com/app/btc/define/katana_mk2.json"),
            "https://api.roland.com/app/btc/define/katana_mk2.json",
        )

    def test_everything_else_is_refused(self):
        for url in (
            "https://example.com/",
            "https://api.roland.com.evil.example/",
            "https://api.roland.com@evil.example/",
            "file:///etc/hosts",
            "",
        ):
            with self.subTest(url=url), self.assertRaises(PermissionError):
                checked_url(url)

    def test_redirects_are_held_to_the_allowlist(self):
        request = urllib.request.Request("https://api.roland.com/")
        with self.assertRaises(PermissionError):
            _AllowlistedRedirects().redirect_request(request, None, 302, "Found", {}, "https://evil.example/")


class SplitMessagesTest(unittest.TestCase):
    def split(self, hex_string):
        return [m.hex().upper() for m in split_messages(bytes.fromhex(hex_string))]

    def test_whole_messages_are_kept_apart(self):
        self.assertEqual(
            self.split("F041100000003312600006570340F7C005903C64F8"),
            ["F041100000003312600006570340F7", "C005", "903C64", "F8"],
        )

    def test_stray_data_bytes_are_dropped(self):
        self.assertEqual(self.split("7FC005"), ["C005"])

    def test_unterminated_sysex_runs_to_the_end(self):
        self.assertEqual(self.split("F0410000"), ["F0410000"])


class MidiConnectTest(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.midi = Midi.__new__(Midi)  # no CoreMIDI: _open only needs the emitter
        self.midi._emit = lambda *event: self.events.append(event)

    def open(self, port):
        with mock.patch("builtins.print"):
            return self.midi._open(port, '{"MIDIEntityNameKey": "KATANA"}')

    def test_a_missing_or_unopenable_port_reports_connectfailed(self):
        missing = mock.Mock(get_ports=lambda: ["Other"])
        refused = mock.Mock(get_ports=lambda: ["KATANA"], open_port=mock.Mock(side_effect=RuntimeError("gone")))
        for port in (missing, refused):
            with self.subTest(port=port.get_ports()):
                self.events.clear()
                self.assertIsNone(self.open(port))
                self.assertEqual(self.events, [("midi", "connectfailed", '{"MIDIEntityNameKey": "KATANA"}')])


if __name__ == "__main__":
    unittest.main()
