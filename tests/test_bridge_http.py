import functools
import http.client
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from bts import server

TOKEN = "test-token"


class RecordingBridge:
    def __init__(self):
        self.calls = []

    def dispatch(self, command, args):
        self.calls.append((command, args))
        return "ok"


class BridgeHttpTest(unittest.TestCase):
    """The security rules of doc/bridge-protocol.md, over a real loopback server with a stand-in bridge."""

    @classmethod
    def setUpClass(cls):
        cls.html = Path(tempfile.mkdtemp())
        (cls.html / "index.html").write_text(f"<html>{server.NATIVE_SCRIPT_TAG}</html>")
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), None)
        cls.port = cls.httpd.server_address[1]
        cls.httpd.RequestHandlerClass = functools.partial(
            server.Handler, bridge=RecordingBridge(), port=cls.port, token=TOKEN, directory=str(cls.html)
        )
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()

    def setUp(self):
        self.bridge = RecordingBridge()
        self.httpd.RequestHandlerClass.keywords["bridge"] = self.bridge

    def request(self, method, path, headers=None, body=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        connection.request(method, path, body=body, headers={"Host": f"localhost:{self.port}", **(headers or {})})
        response = connection.getresponse()
        result = response.status, response.read().decode()
        connection.close()
        return result

    def test_command_with_token_reaches_the_bridge(self):
        self.assertEqual(self.request("GET", f"/{TOKEN}/$$app_storage2;key,%2C"), (200, "sok"))
        self.assertEqual(self.bridge.calls, [("app_storage2", ["key", ","])])

    def test_command_without_or_with_a_wrong_token_is_refused(self):
        for path in ("/$$app_storage", "/wrong/$$app_storage", "/%C3%A9/$$app_storage"):
            with self.subTest(path=path):
                self.assertEqual(self.request("GET", path)[0], 403)
        self.assertEqual(self.bridge.calls, [])

    def test_foreign_host_is_refused(self):
        self.assertEqual(self.request("GET", f"/{TOKEN}/$$app_storage", {"Host": f"evil.example:{self.port}"})[0], 403)
        self.assertEqual(self.request("GET", "/index.html", {"Host": "evil.example"})[0], 403)

    def test_other_origins_are_refused(self):
        for headers in ({"Origin": "https://evil.example"}, {"Sec-Fetch-Site": "cross-site"}):
            with self.subTest(headers=headers):
                self.assertEqual(self.request("GET", f"/{TOKEN}/$$app_storage", headers)[0], 403)
        self.assertEqual(self.bridge.calls, [])

    def test_post_command_gets_string_arguments(self):
        status, _ = self.request("POST", f"/{TOKEN}/$$app_storage2", body=b'[3, ""]')
        self.assertEqual(status, 200)
        self.assertEqual(self.bridge.calls, [("app_storage2", ["3", ""])])

    def test_post_with_a_bad_length_is_refused(self):
        for length in ("-1", "abc", str(server.MAX_POST_BYTES + 1)):
            with self.subTest(length=length):
                self.assertEqual(self.request("POST", f"/{TOKEN}/$$x", {"Content-Length": length})[0], 400)

    def test_post_without_token_is_dropped_not_dispatched(self):
        self.assertEqual(self.request("POST", "/$$app_storage2", body=b'["k", "v"]')[0], 204)
        self.assertEqual(self.bridge.calls, [])

    def test_proxy_needs_the_token(self):
        self.assertEqual(self.request("GET", "/wrong/__proxy?url=https%3A%2F%2Fapi.roland.com%2F")[0], 403)

    def test_index_carries_the_token_in_xhrport(self):
        status, body = self.request("GET", "/index.html")
        self.assertEqual(status, 200)
        self.assertIn(f"window.$$xhrport = '{self.port}/{TOKEN}';", body)

    def test_page_log_lines_are_escaped(self):
        with mock.patch("builtins.print") as printed:
            self.request("GET", "/__bts/log;boom%0A%5Bbts%5D%20forged")
        self.assertEqual(printed.call_args.args[0], "[js] 'boom\\n[bts] forged'")


class PermittedPathsTest(unittest.TestCase):
    def setUp(self):
        with mock.patch("bts.server.Midi"):
            self.bridge = server.Bridge(tempfile.mkdtemp())

    def test_app_folders_are_permitted(self):
        target = Path(self.bridge._fs_path("temporary")) / "backup.alb"
        self.assertEqual(self.bridge._permitted(target), target.resolve())

    def test_other_paths_and_traversal_are_refused(self):
        escape = Path(self.bridge._fs_path("library")) / "../../../../etc/hosts"
        for path in ("/etc/hosts", str(Path.home() / "x.txt"), str(escape)):
            with self.subTest(path=path), self.assertRaises(PermissionError):
                self.bridge._permitted(path)

    def test_exec_opens_web_links_only(self):
        for target in ("/Applications/Calculator.app", "-aCalculator", "file:///etc/hosts"):
            with self.subTest(target=target), self.assertRaises(PermissionError):
                self.bridge._fs_exec(target)


if __name__ == "__main__":
    unittest.main()
