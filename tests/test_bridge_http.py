import functools
import http.client
import os
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
            server.Handler, bridge=None, port=cls.port, token=TOKEN, directory=str(cls.html)
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
        result = response.status, response.read().decode(), response.headers
        connection.close()
        return result

    def status(self, *args, **kwargs):
        return self.request(*args, **kwargs)[0]

    def test_command_with_token_reaches_the_bridge(self):
        self.assertEqual(self.request("GET", f"/{TOKEN}/$$app_storage2;key,%2C")[:2], (200, "sok"))
        self.assertEqual(self.bridge.calls, [("app_storage2", ["key", ","])])

    def test_command_without_or_with_a_wrong_token_is_refused(self):
        for path in ("/$$app_storage", "/wrong/$$app_storage", "/%C3%A9/$$app_storage", "/wrong/proxy?url=x"):
            with self.subTest(path=path):
                self.assertEqual(self.status("GET", path), 403)
        self.assertEqual(self.status("POST", "/$$app_storage2", body=b'["k", "v"]'), 403)
        self.assertEqual(self.bridge.calls, [])

    def test_foreign_host_is_refused_for_every_method(self):
        foreign = {"Host": f"evil.example:{self.port}"}
        for method, path in (("GET", f"/{TOKEN}/$$app_storage"), ("GET", "/index.html"), ("HEAD", "/index.html")):
            with self.subTest(method=method, path=path):
                self.assertEqual(self.status(method, path, foreign), 403)

    def test_other_origins_are_refused(self):
        for headers in ({"Origin": "https://evil.example"}, {"Sec-Fetch-Site": "cross-site"}):
            with self.subTest(headers=headers):
                self.assertEqual(self.status("GET", f"/{TOKEN}/$$app_storage", headers), 403)
                self.assertEqual(self.status("POST", f"/{TOKEN}/$$app_storage2", headers, b'["k", "v"]'), 403)
                self.assertEqual(self.status("GET", "/index.html", headers), 403)
        self.assertEqual(self.bridge.calls, [])

    def test_the_page_own_origin_is_accepted(self):
        page = {"Origin": f"http://localhost:{self.port}", "Sec-Fetch-Site": "same-origin"}
        self.assertEqual(self.status("POST", f"/{TOKEN}/$$app_storage2", page, b'["3", ""]'), 200)
        self.assertEqual(self.bridge.calls, [("app_storage2", ["3", ""])])

    def test_post_arguments_arrive_as_strings(self):
        self.assertEqual(self.status("POST", f"/{TOKEN}/$$app_storage2", body=b'[3, ""]'), 200)
        self.assertEqual(self.bridge.calls, [("app_storage2", ["3", ""])])

    def test_post_with_a_bad_length_is_refused(self):
        for length in ("-1", "abc", str(server.MAX_POST_BYTES + 1)):
            with self.subTest(length=length):
                self.assertEqual(self.status("POST", f"/{TOKEN}/$$x", {"Content-Length": length}), 400)

    def test_telemetry_posts_are_dropped(self):
        self.assertEqual(self.status("POST", "/index.html", body=b"stats"), 204)
        url = "https%3A%2F%2Fapi.roland.com%2Fapp%2Fbtc%2F1%2Fstatuslogs%2F"
        self.assertEqual(self.status("POST", f"/{TOKEN}/proxy?url={url}", body=b"stats"), 204)
        self.assertEqual(self.bridge.calls, [])

    def test_index_carries_the_token_and_cannot_be_framed(self):
        status, body, headers = self.request("GET", "/index.html", {"Sec-Fetch-Site": "none"})
        self.assertEqual(status, 200)
        self.assertIn(f"window.$$xhrport = '{self.port}/{TOKEN}';", body)
        self.assertEqual(headers["X-Frame-Options"], "DENY")
        self.assertEqual(headers["Content-Security-Policy"], "frame-ancestors 'none'")

    def test_unsupported_index_explains_itself(self):
        index = self.html / "index.html"
        original = index.read_text()
        index.write_text("<html></html>")
        try:
            status, body, _ = self.request("GET", "/index.html")
        finally:
            index.write_text(original)
        self.assertEqual(status, 500)
        self.assertIn("not supported", body)

    def test_page_log_lines_need_the_token_and_are_escaped(self):
        with mock.patch("builtins.print") as printed:
            self.assertEqual(self.status("POST", "/wrong/log", body=b"x"), 403)
            self.request("POST", f"/{TOKEN}/log", body=b"boom\n[bts] forged")
        self.assertEqual(printed.call_args.args[0], "[js] 'boom\\n[bts] forged'")


class EncodingTest(unittest.TestCase):
    def test_types_follow_native_js_decode(self):
        encoded = [server.encode(None), server.encode(True), server.encode(False), server.encode(7), server.encode("x")]
        self.assertEqual(encoded, ["v", "b1", "b", "d7", "sx"])

    def test_empty_post_body_has_no_arguments(self):
        self.assertEqual(server.post_args(b""), [])


class BridgeFilesTest(unittest.TestCase):
    def setUp(self):
        with mock.patch("bts.server.Midi"):
            self.bridge = server.Bridge(tempfile.mkdtemp())

    def test_app_folders_are_permitted(self):
        target = Path(self.bridge._fs_path("temporary")) / "backup.alb"
        self.assertEqual(self.bridge._permitted(target), target.resolve())

    def test_a_file_chosen_in_a_dialog_is_permitted(self):
        chosen = Path(tempfile.mkdtemp()) / "Foo.tsl"
        self.bridge._chosen_files.add(chosen.resolve())
        self.assertEqual(self.bridge._permitted(chosen), chosen.resolve())

    def test_other_paths_and_traversal_are_refused(self):
        escape = Path(self.bridge._fs_path("library")) / "../../../../etc/hosts"
        for path in ("/etc/hosts", str(Path.home() / "x.txt"), str(escape)):
            with self.subTest(path=path), self.assertRaises(PermissionError):
                self.bridge._permitted(path)

    def test_save_dialog_refuses_an_extension_that_leaves_the_folder(self):
        for ext in ("tsl/../../Library/LaunchAgents/x.plist", "", "t.sl"):
            with self.subTest(ext=ext), self.assertRaises(PermissionError):
                self.bridge._fs_savefilename("Backup", ext)

    def test_exec_opens_web_links_only(self):
        for target in ("/Applications/Calculator.app", "-aCalculator", "file:///etc/hosts"):
            with self.subTest(target=target), self.assertRaises(PermissionError):
                self.bridge._fs_exec(target)

    def test_storage2_reads_writes_and_deletes(self):
        self.assertEqual(self.bridge._app_storage2("0"), "")
        self.bridge._app_storage2("0", "liveset")
        self.assertEqual(self.bridge._app_storage2("0"), "liveset")
        self.bridge._app_storage2("0", "")
        self.assertEqual(self.bridge._app_storage2("0"), "")
        self.assertEqual([p for p in os.listdir(self.bridge._storage2.directory) if p.startswith(".tmp")], [])

    def test_closing_lets_the_page_answer_and_destroys_the_window_once(self):
        window = mock.Mock()
        self.bridge.window = window
        self.assertFalse(self.bridge.on_closing())  # first close waits for the page
        self.assertEqual(self.bridge._app_getevent(), "app\fcommand\fexit")
        self.assertFalse(self.bridge.on_closing())  # so does a second click before the page answers
        self.assertIsNone(self.bridge._app_getevent())  # without asking the page twice
        self.bridge._app_exit()  # the page's $$app_exit
        self.bridge._app_exit()  # the fallback timer, had it not been cancelled
        window.destroy.assert_called_once()
        self.assertTrue(self.bridge._exit_timer.finished.is_set())  # cancelled
        self.assertTrue(self.bridge.on_closing())

    def test_storage2_refuses_keys_that_name_a_folder(self):
        for key in ("", ".", ".."):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.bridge._app_storage2(key, "x")


if __name__ == "__main__":
    unittest.main()
