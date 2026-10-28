import functools
import http.client
import io
import json
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
    commands = ["app_storage2", "midi_send"]

    def __init__(self, result="ok"):
        self.calls = []
        self.result = result

    def dispatch(self, command, args):
        self.calls.append((command, args))
        return self.result


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

    def command(self, path, args=(), headers=None, body=None):
        """A command the way the page script sends it: POST, JSON array of strings."""
        headers = {"Content-Type": "application/json", **(headers or {})}
        return self.request("POST", path, headers, json.dumps(list(args)).encode() if body is None else body)

    def test_command_with_token_reaches_the_bridge_and_answers_json(self):
        self.assertEqual(self.command(f"/{TOKEN}/$$app_storage2", ["key", ","])[:2], (200, '"ok"'))
        self.assertEqual(self.bridge.calls, [("app_storage2", ["key", ","])])

    def test_no_result_answers_null(self):
        self.bridge.result = None
        self.assertEqual(self.command(f"/{TOKEN}/$$app_getevent")[:2], (200, "null"))

    def test_a_failing_command_answers_500_with_its_message(self):
        self.bridge.dispatch = mock.Mock(side_effect=PermissionError("refused"))
        with mock.patch("builtins.print"):
            self.assertEqual(self.command(f"/{TOKEN}/$$fs_exec", ["file:///"])[:2], (500, "refused"))

    def test_command_without_or_with_a_wrong_token_is_refused(self):
        for path in ("/$$app_storage", "/wrong/$$app_storage", "/%C3%A9/$$app_storage"):
            with self.subTest(path=path):
                self.assertEqual(self.command(path)[0], 403)
        self.assertEqual(self.status("GET", "/wrong/proxy?url=x"), 403)
        self.assertEqual(self.bridge.calls, [])

    def test_commands_are_post_only(self):
        self.assertEqual(self.status("GET", f"/{TOKEN}/$$app_storage"), 405)
        self.assertEqual(self.bridge.calls, [])

    def test_commands_need_json_arguments_of_strings(self):
        plain = self.command(f"/{TOKEN}/$$app_storage2", ["k", "v"], {"Content-Type": "text/plain"})
        self.assertEqual(plain[0], 415)  # what a cross-site form could send without a preflight
        for body in (b"not json", b'{"k": "v"}', b'[3, ""]', b"[null]", b"[" * 100_000):
            with self.subTest(body=body[:10]):
                self.assertEqual(self.command(f"/{TOKEN}/$$app_x", body=body)[0], 400)
        self.assertEqual(self.bridge.calls, [])

    def test_foreign_host_is_refused_for_every_method(self):
        foreign = {"Host": f"evil.example:{self.port}"}
        self.assertEqual(self.command(f"/{TOKEN}/$$app_storage", headers=foreign)[0], 403)
        for method in ("GET", "HEAD"):
            with self.subTest(method=method):
                self.assertEqual(self.status(method, "/index.html", foreign), 403)

    def test_other_origins_are_refused(self):
        for headers in ({"Origin": "https://evil.example"}, {"Sec-Fetch-Site": "cross-site"}):
            with self.subTest(headers=headers):
                self.assertEqual(self.command(f"/{TOKEN}/$$app_storage2", ["k", "v"], headers)[0], 403)
                self.assertEqual(self.status("GET", "/index.html", headers), 403)
        self.assertEqual(self.bridge.calls, [])

    def test_the_page_own_origin_is_accepted_on_every_loopback_name(self):
        for host in ("localhost", "127.0.0.1", "[::1]"):
            with self.subTest(host=host):
                page = {"Origin": f"http://{host}:{self.port}", "Sec-Fetch-Site": "same-origin"}
                self.assertEqual(self.command(f"/{TOKEN}/$$app_storage2", ["3", ""], page)[0], 200)

    def test_refused_requests_are_logged_without_the_token(self):
        encoded = "%74" + TOKEN[1:]  # the same token, percent-encoded
        with mock.patch("sys.stderr", new_callable=io.StringIO) as log:
            for token in (TOKEN, encoded):
                self.command(f"/{token}/$$app_storage2", headers={"Origin": "https://evil.example"})
        self.assertEqual(log.getvalue().count(" 403 "), 2)
        self.assertNotIn(TOKEN[1:], log.getvalue())

    def test_command_names_are_checked_before_anything_is_run_or_logged(self):
        with mock.patch("sys.stderr", new_callable=io.StringIO) as log:
            self.assertEqual(self.command(f"/{TOKEN}/$$x%0a[bts]%20forged")[0], 404)
        self.assertNotIn("\n[bts] forged", log.getvalue())
        self.assertEqual(self.bridge.calls, [])

    def test_post_with_a_bad_length_is_refused(self):
        for length in ("-1", "abc", str(server.MAX_POST_BYTES + 1)):
            with self.subTest(length=length):
                self.assertEqual(self.status("POST", f"/{TOKEN}/$$app_x", {"Content-Length": length}), 400)

    def test_telemetry_posts_are_dropped(self):
        self.assertEqual(self.status("POST", "/index.html", body=b"stats"), 204)
        url = "https%3A%2F%2Fapi.roland.com%2Fapp%2Fbtc%2F1%2Fstatuslogs%2F"
        self.assertEqual(self.status("POST", f"/{TOKEN}/proxy?url={url}", body=b"stats"), 204)
        self.assertEqual(self.bridge.calls, [])

    def test_no_spelling_of_the_index_skips_the_origin_check(self):
        for path in ("/", "/./", "/./index.html", "/%69ndex.html", "/index.html?x"):
            with self.subTest(path=path):
                self.assertEqual(self.status("GET", path, {"Sec-Fetch-Site": "cross-site"}), 403)
                self.assertIn(f"var base = '/{TOKEN}/';", self.request("GET", path)[1])

    def test_index_hooks_native_js_with_the_token_and_cannot_be_framed(self):
        status, body, headers = self.request("GET", "/index.html", {"Sec-Fetch-Site": "none"})
        self.assertEqual(status, 200)
        self.assertLess(body.index(f"var base = '/{TOKEN}/';"), body.index(server.NATIVE_SCRIPT_TAG))
        self.assertIn('["app_storage2", "midi_send"].forEach', body)
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

    def test_no_startevent_command_so_native_js_polls_for_events(self):
        self.assertIn("app_getevent", self.bridge.commands)
        self.assertNotIn("app_startevent", self.bridge.commands)

    def test_storage2_refuses_keys_that_name_a_folder(self):
        for key in ("", ".", ".."):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.bridge._app_storage2(key, "x")


if __name__ == "__main__":
    unittest.main()
