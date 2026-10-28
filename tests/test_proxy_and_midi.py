import unittest
import urllib.request

from bts.midi import split_messages
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


if __name__ == "__main__":
    unittest.main()
