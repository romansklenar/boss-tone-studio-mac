"""Local HTTP backend speaking the `$$command;arg1,arg2` protocol of Roland's `js/lib/native.js`.

Roland's own Mac shell runs the same kind of server: when the user agent contains `roland.quattro` and
`window.$$xhrport` is set, every `$native.*` call becomes a synchronous GET to `http://localhost:<port>/$$…`, and the
answer is a type-prefixed string (`v` undefined, `b`/`b1` boolean, `d` int, `f` float, `s` string). Native → JS
events are queued here and polled by the page through `$$app_getevent`.
"""

import collections
import functools
import hmac
import json
import os
import secrets
import socket
import subprocess
import tempfile
import threading
import urllib.parse
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from bts import proxy
from bts.midi import Midi

TRACE = os.environ.get("BTS_TRACE") == "1"  # logs every bridge command and native event

MAX_POST_BYTES = 64 * 1024 * 1024  # an All Data Backup is ~81 KB
MAX_LOG_CHARS = 500

NATIVE_SCRIPT_TAG = '<script src="js/lib/native.js"></script>'

# native.js builds 'http://localhost:' + $$xhrport + '/' + command, so a token appended to the port becomes a path
# prefix that pages from other origins cannot know.
PRE_NATIVE = """<script>
window.$$xhrport = '%(port)d/%(token)s';
(function () {
  var ua = navigator.userAgent;
  if (ua.indexOf('roland.quattro') < 0) {
    Object.defineProperty(navigator, 'userAgent', { get: function () { return ua + ' roland.quattro(Mac)'; } });
  }
  window.addEventListener('error', function (e) {
    var x = new XMLHttpRequest();
    x.open('GET', '/__bts/log;' + encodeURIComponent(e.message + ' @ ' + e.filename + ':' + e.lineno), true);
    x.send(null);
  });
})();
</script>
"""

# Roland routes midi.send through webkit.messageHandlers.quattro2, which only their native shell registers.
# Backups and livesets outgrow a GET URL (http.server caps the request line at 64 KB), so those writes go as POST.
POST_NATIVE = """
<script>
(function () {
  function call(verb, method, query, body) {
    var x = new XMLHttpRequest();
    x.open(verb, 'http://localhost:' + window.$$xhrport + '/' + method + query, false);
    x.send(body);
    if (x.responseText.charAt(0) === 'e') throw new Error(x.responseText.slice(1));
  }
  var readStorage2 = $native.app.storage2;
  $native.midi.send = function (msg) { call('GET', '$$midi_send', ';' + encodeURIComponent(msg), null); };
  $native.fs.writeString = function (file, text) {
    call('POST', '$$fs_writeString', '', JSON.stringify([file, text]));
  };
  $native.app.storage2 = function (key, data) {
    if (data === undefined) return readStorage2(key);
    call('POST', '$$app_storage2', '', JSON.stringify([key, data]));
  };
  // Tone Central's servers send no CORS headers, so its absolute URLs go through the local proxy.
  var ajax = $.ajax;
  $.ajax = function (options) {
    if (options && /^https?:\\/\\//.test(options.url)) {
      options.url = 'http://localhost:' + window.$$xhrport + '/__proxy?url=' + encodeURIComponent(options.url);
    }
    return ajax.apply(this, arguments);
  };
})();
</script>"""


def post_args(body):
    """Arguments of a POSTed command, as strings like GET's: the page passes liveset IDs as numbers."""
    return [str(arg) for arg in json.loads(body or b"[]")]


def encode(value):
    if value is None:
        return "v"
    if isinstance(value, bool):
        return "b1" if value else "b"
    if isinstance(value, int):
        return f"d{value}"
    if isinstance(value, float):
        return f"f{value}"
    return f"s{value}"


class Bridge:
    """Implements the `$native` commands BOSS TONE STUDIO for KATANA MkII actually calls."""

    def __init__(self, data_dir):
        self.window = None
        self._data_dir = Path(data_dir).resolve()
        self._storage2_dir = self._data_dir / "storage2"
        self._storage2_dir.mkdir(parents=True, exist_ok=True)
        self._temp_dir = Path(tempfile.mkdtemp(prefix="bts-")).resolve()
        self._chosen_files = set()
        self._events = collections.deque()
        self._exiting = False
        self.midi = Midi(self.emit)
        self._commands = {
            "app_ready": lambda: None,
            "app_startevent": lambda *_: None,  # undefined → native.js falls back to polling $$app_getevent
            "app_getevent": self._app_getevent,
            "app_storage": self._app_storage,
            "app_storage2": self._app_storage2,
            "app_control": lambda *_: None,  # 'indicator start|stop', 'set_window_size:…'
            "app_importfile": lambda *_: None,
            "app_exportfile": lambda *_: None,
            "app_exit": self._app_exit,
            "fs_separator": lambda: "/",
            "fs_path": self._fs_path,
            "fs_exec": self._fs_exec,
            "fs_readString": lambda path: self._permitted(path).read_text(encoding="utf-8"),
            "fs_writeString": self._fs_write_string,
            "fs_openfilename": self._fs_openfilename,
            "fs_savefilename": self._fs_savefilename,
            "midi_inendpoints": self.midi.inputs,
            "midi_outendpoints": self.midi.outputs,
            "midi_inconnect": self.midi.connect_input,
            "midi_outconnect": self.midi.connect_output,
            "midi_indisconnect": self.midi.disconnect_input,
            "midi_outdisconnect": self.midi.disconnect_output,
            "midi_send": self.midi.send,
            "midi_panel": lambda: None,
        }

    def dispatch(self, command, args):
        handler = self._commands.get(command)
        if handler is None:
            print(f"[bts] unimplemented $${command} {args}")
            return None
        if TRACE and command != "app_getevent":
            print(f"[trace] -> $${command} {[a[:120] for a in args]}", flush=True)
        return handler(*args)

    def emit(self, prop, kind, *args):
        if TRACE:
            print(f"[trace] <- {prop}.{kind} {[a[:120] for a in args]}", flush=True)
        self._events.append("\f".join((prop, kind, *args)))

    def on_closing(self):
        """Lets the page take the amp out of editor mode first; it answers with $$app_exit."""
        if self._exiting:
            return True
        self._exiting = True
        self.emit("app", "command", "exit")
        threading.Timer(2.0, self._app_exit).start()
        return False

    def _app_getevent(self):
        try:
            return self._events.popleft()
        except IndexError:
            return None

    def _app_storage(self, data=None):
        path = self._data_dir / "storage.json"
        if data is None:
            return path.read_text(encoding="utf-8") if path.exists() else ""
        path.write_text(data, encoding="utf-8")

    def _app_storage2(self, key, data=None):
        path = self._storage2_dir / urllib.parse.quote(key, safe="")
        if data is None:
            return path.read_text(encoding="utf-8") if path.exists() else ""
        if data:
            path.write_text(data, encoding="utf-8")
        else:
            path.unlink(missing_ok=True)

    def _app_exit(self):
        self._exiting = True
        self.midi.disconnect_all()
        if self.window:
            self.window.destroy()
            self.window = None

    def _fs_path(self, where):
        return {"temporary": f"{self._temp_dir}/", "library": f"{self._data_dir}/"}.get(where, "")

    def _fs_write_string(self, path, text):
        path = self._permitted(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def _fs_exec(self, url):
        """The MkII only opens web pages (driver download, Roland links); nothing local is launched."""
        if not url.startswith(("https://", "http://")):
            raise PermissionError(f"refusing to open {url!r}")
        subprocess.Popen(["open", url])

    def _permitted(self, path):
        """Files are reachable only inside the app's own folders or where the user pointed a file dialog."""
        path = Path(path).resolve()
        if path in self._chosen_files or any(path.is_relative_to(d) for d in (self._data_dir, self._temp_dir)):
            return path
        raise PermissionError(f"{path} was not chosen in a file dialog")

    def _fs_openfilename(self, filter_json=None):
        extensions = json.loads(filter_json) if filter_json else []
        file_types = tuple(f"{ext.upper()} (*.{ext})" for ext in extensions)
        self._file_dialog("openfilename", dialog_type="OPEN", file_types=file_types)

    def _fs_savefilename(self, name, ext):
        self._file_dialog("savefilename", dialog_type="SAVE", save_filename=f"{name}.{ext}", ext=ext)

    def _file_dialog(self, event, dialog_type, ext=None, **options):
        """Answers asynchronously through an fs event, like Roland's shell, so the sync XHR returns at once."""
        if not self.window:
            print(f"[bts] fs_{event} needs the app window (not available in --browser mode)")
            return

        def run():
            import webview

            result = self.window.create_file_dialog(getattr(webview.FileDialog, dialog_type), **options)
            if isinstance(result, (list, tuple)):
                result = result[0] if result else None
            if result and ext and not result.endswith(f".{ext}"):
                result = f"{result}.{ext}"
            if result:
                self._chosen_files.add(Path(result).resolve())
            self.emit("fs", event, result or "")

        threading.Thread(target=run, daemon=True).start()


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, bridge, port, token, **kwargs):
        self.bridge = bridge
        self.port = port
        self.token = token
        super().__init__(*args, **kwargs)

    def do_GET(self):
        if not self._trusted_host():
            return self.send_error(403)
        path, _, raw_args = urllib.parse.urlsplit(self.path).path.partition(";")
        path = urllib.parse.unquote(path)
        token, _, command = path[1:].partition("/$$")
        if command:
            if not self._has_token(token):
                return self.send_error(403)
            return self._native(command, raw_args)
        token, _, route = path[1:].partition("/")
        if route == "__proxy":
            if not self._has_token(token) or not self._same_origin():
                return self.send_error(403)
            return self._proxy(urllib.parse.urlsplit(self.path).query)
        if path.startswith("/$$"):
            return self.send_error(403)
        if path == "/__bts/log":
            print(f"[js] {urllib.parse.unquote(raw_args)[:MAX_LOG_CHARS]!r}")  # repr: the page cannot forge log lines
            return self._reply("v")
        if path in ("/", "/index.html"):
            return self._index()
        return super().do_GET()

    def do_POST(self):
        if not self._trusted_host():
            return self.send_error(403)
        token, _, command = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)[1:].partition("/$$")
        if command:
            if not self._has_token(token) or not self._same_origin():
                return self.send_error(403)
            length = self.headers.get("Content-Length", "0")
            if not (length.isascii() and length.isdigit()) or int(length) > MAX_POST_BYTES:
                return self.send_error(400)
            return self._reply(self._call(command, post_args(self.rfile.read(int(length)))))
        # Roland's usage telemetry (log_manager.js, also through the proxy) is the only other POST; it goes nowhere.
        self.send_response(204)
        self.end_headers()

    def _proxy(self, query):
        target = urllib.parse.parse_qs(query).get("url", [""])[0]
        try:
            status, content_type, body = proxy.fetch(target)
        except PermissionError as error:
            print(f"[bts] {error}")
            return self.send_error(403)
        except OSError as error:  # URLError, timeouts, TLS failures
            print(f"[bts] proxy {target} failed: {error!r}")
            return self.send_error(502)
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, fmt, *args):
        if not str(args[1] if len(args) > 1 else "").startswith(("2", "3")):
            super().log_message(fmt, *args)

    def _native(self, command, raw_args):
        if not self._same_origin():
            return self.send_error(403)
        args = [urllib.parse.unquote(a) for a in raw_args.split(",")] if raw_args or ";" in self.path else []
        self._reply(self._call(command, args))

    def _call(self, command, args):
        try:
            return encode(self.bridge.dispatch(command, args))
        except Exception as error:  # the page decodes anything else than v/b/d/f/s as a thrown Error
            print(f"[bts] $${command} failed: {error!r}")
            return f"e{error}"

    def _index(self):
        html = (Path(self.directory) / "index.html").read_text(encoding="utf-8")
        if NATIVE_SCRIPT_TAG not in html:
            raise RuntimeError("index.html no longer loads js/lib/native.js; unsupported app version")
        pre_native = PRE_NATIVE % {"port": self.port, "token": self.token}
        html = html.replace(NATIVE_SCRIPT_TAG, pre_native + NATIVE_SCRIPT_TAG + POST_NATIVE)
        self._reply(html, "text/html; charset=utf-8")

    def _reply(self, body, content_type="text/plain; charset=utf-8"):
        data = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _has_token(self, token):
        # Bytes, because compare_digest refuses non-ASCII str and the path may hold anything.
        return hmac.compare_digest(token.encode(), self.token.encode())

    def _trusted_host(self):
        """Rejects DNS-rebinding requests: only loopback host names may reach the backend."""
        return self.headers.get("Host") in {f"{h}:{self.port}" for h in ("localhost", "127.0.0.1", "[::1]")}

    def _same_origin(self):
        """Keeps other web pages in the user's browser from driving the file-system and MIDI commands."""
        origin = self.headers.get("Origin")
        fetch_site = self.headers.get("Sec-Fetch-Site")
        return origin in (None, f"http://localhost:{self.port}") and fetch_site in (None, "same-origin", "none")


class IPv6Server(ThreadingHTTPServer):
    address_family = socket.AF_INET6


def start(html_dir, data_dir):
    """Serves on both loopback addresses, because native.js hard-codes `localhost`. Returns (port, bridge)."""
    bridge = Bridge(data_dir)
    servers = [ThreadingHTTPServer(("127.0.0.1", 0), None)]
    port = servers[0].server_address[1]
    try:
        servers.append(IPv6Server(("::1", port), None))
    except OSError as error:
        print(f"[bts] IPv6 loopback unavailable ({error}); localhost must resolve to 127.0.0.1")
    token = secrets.token_urlsafe(24)
    handler = functools.partial(Handler, bridge=bridge, port=port, token=token, directory=os.fspath(html_dir))
    for server in servers:
        server.RequestHandlerClass = handler
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
    return port, bridge
