"""Local HTTP bridge for Roland's web app; the protocol and its security rules are in doc/bridge-protocol.md."""

import atexit
import collections
import errno
import functools
import hmac
import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import tempfile
import threading
import urllib.parse
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from bts import proxy, storage
from bts.midi import Midi

TRACE = os.environ.get("BTS_TRACE") == "1"  # logs every bridge command and native event

MAX_POST_BYTES = 64 * 1024 * 1024  # an All Data Backup is ~81 KB
MAX_LOG_CHARS = 500
MAX_QUEUED_EVENTS = 10_000  # events pile up only while no page polls
COMMAND_ROUTE = re.compile(r"\$\$[a-z]+_[A-Za-z0-9]+")
BRIDGE_ROUTES = ("proxy", "log")  # besides `$$<command>`; everything else is Roland's static files

NATIVE_SCRIPT_TAG = '<script src="js/lib/native.js"></script>'

# native.js checks for window.$$app before anything else and then calls window['$$' + object][method](args…) for
# every command, using the result as is. This script defines those methods, one per bridge command, each forwarding the
# call behind a per-launch token. The bridge has no app_startevent, so native.js keeps polling $$app_getevent.
PRE_NATIVE = """<script>
(function () {
  var base = '/%(token)s/';
  function call(command, args) {
    var x = new XMLHttpRequest();
    x.open('POST', base + command, false);
    x.setRequestHeader('Content-Type', 'application/json');
    x.send(JSON.stringify(args.map(String)));  // String(): what native.js's own URL transport would send
    if (x.status !== 200) throw new Error(x.status === 500 ? x.responseText : 'bridge answered HTTP ' + x.status);
    var value = JSON.parse(x.responseText);
    return value === null ? undefined : value;
  }
  %(commands)s.forEach(function (command) {
    var split = command.indexOf('_'), object = '$$' + command.slice(0, split);
    (window[object] = window[object] || {})[command.slice(split + 1)] = function () {
      return call('$$' + command, Array.prototype.slice.call(arguments));
    };
  });
  window.addEventListener('error', function (e) {
    var x = new XMLHttpRequest();
    x.open('POST', base + 'log', true);
    x.send(e.message + ' @ ' + e.filename + ':' + e.lineno);
  });
  // Tone Central's servers send no CORS headers, so its absolute URLs go through the local proxy.
  $.ajaxPrefilter(function (options) {
    if (/^https?:\\/\\//.test(options.url)) {
      options.url = base + 'proxy?url=' + encodeURIComponent(options.url);
      options.crossDomain = false;
    }
  });
})();
</script>
"""

UNSUPPORTED_PAGE = """<!doctype html><meta charset="utf-8"><title>Unsupported</title>
<p>This version of Roland's editor is not supported: its <code>index.html</code> no longer loads
<code>js/lib/native.js</code>. Rebuild with <code>make roland-assets</code>.</p>"""


def command_args(body):
    """A command's arguments: a JSON array of strings, as the page script sends them."""
    args = json.loads(body)
    if not (isinstance(args, list) and all(isinstance(arg, str) for arg in args)):
        raise ValueError("arguments must be a JSON array of strings")
    return args


def _ignore(*_):
    return None


def _trace(arrow, label, args):
    if TRACE:
        print(f"[trace] {arrow} {label} {[a[:120] for a in args]}", flush=True)


class Bridge:
    """Implements the `$native` commands BOSS TONE STUDIO for KATANA MkII actually calls."""

    def __init__(self, data_dir):
        self.window = None
        self._data_dir = Path(data_dir).resolve()
        self._storage2 = storage.Storage2(self._data_dir)
        self._temp_dir = Path(tempfile.mkdtemp(prefix="bts-")).resolve()
        atexit.register(shutil.rmtree, self._temp_dir, ignore_errors=True)
        self._chosen_files = set()
        self._events = collections.deque(maxlen=MAX_QUEUED_EVENTS)
        self._exit_lock = threading.Lock()
        self._exit_timer = None
        self._exiting = False
        self.midi = Midi(self.emit)
        self._commands = {
            "app_ready": _ignore,
            "app_getevent": self._app_getevent,
            "app_storage": self._app_storage,
            "app_storage2": self._app_storage2,
            "app_control": _ignore,  # 'indicator start|stop', 'set_window_size:…'
            "app_importfile": _ignore,
            "app_exportfile": _ignore,
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
            "midi_panel": _ignore,
        }

    @property
    def commands(self):
        return sorted(self._commands)

    def dispatch(self, command, args):
        handler = self._commands.get(command)
        if handler is None:
            print(f"[bts] unimplemented $${command} {args}")
            return None
        if command != "app_getevent":
            _trace("->", f"$${command}", args)
        return handler(*args)

    def emit(self, prop, kind, *args):
        _trace("<-", f"{prop}.{kind}", args)
        self._events.append("\f".join((prop, kind, *args)))

    def on_closing(self):
        """Lets the page take the amp out of editor mode first; it answers with $$app_exit."""
        with self._exit_lock:
            if self.window is None:  # _app_exit is destroying it
                return True
            if self._exiting:  # a second click while the page is still answering
                return False
            self._exiting = True
            self._exit_timer = threading.Timer(2.0, self._app_exit)
            self._exit_timer.daemon = True
            self._exit_timer.start()
        self.emit("app", "command", "exit")
        return False

    def _app_getevent(self):
        try:
            return self._events.popleft()
        except IndexError:
            return None

    def _app_storage(self, data=None):
        path = self._data_dir / "storage.json"
        if data is None:
            return storage.read(path) or ""
        storage.write_atomically(path, data)

    def _app_storage2(self, key, data=None):
        if data is None:
            return self._storage2.read(key) or ""
        self._storage2.write(key, data)

    def _app_exit(self):
        with self._exit_lock:
            self._exiting = True
            if self._exit_timer:
                self._exit_timer.cancel()
            window, self.window = self.window, None
        self.midi.disconnect_all()
        if window:
            window.destroy()

    def _fs_path(self, where):
        return {"temporary": f"{self._temp_dir}/", "library": f"{self._data_dir}/"}.get(where, "")

    def _fs_write_string(self, path, text):
        path = self._permitted(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        storage.write_atomically(path, text)

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
        if not re.fullmatch(r"[A-Za-z0-9]{1,10}", ext):  # appended to the chosen path, so it must not hold a "/"
            raise PermissionError(f"refusing extension {ext!r}")
        self._file_dialog("savefilename", dialog_type="SAVE", save_filename=f"{name}.{ext}", ext=ext)

    def _file_dialog(self, event, dialog_type, ext=None, **options):
        """Answers asynchronously through an fs event, like Roland's shell, so the sync XHR returns at once."""
        window = self.window
        if not window:
            print(f"[bts] fs_{event} needs the app window (not available in --browser mode)")
            return

        def run():
            import webview

            result = window.create_file_dialog(getattr(webview.FileDialog, dialog_type), **options)
            if isinstance(result, (list, tuple)):
                result = result[0] if result else None
            if result and ext and not result.lower().endswith(f".{ext.lower()}"):
                result = f"{result}.{ext}"
            if result:
                self._chosen_files.add(Path(result).resolve())
            self.emit("fs", event, result or "")

        threading.Thread(target=run, daemon=True).start()


class Handler(SimpleHTTPRequestHandler):
    # Keep-alive: the page polls every 50 ms with synchronous XHR; a new connection and thread each time adds up.
    protocol_version = "HTTP/1.1"
    server_version = "bts"
    sys_version = ""

    def __init__(self, *args, bridge, port, token, **kwargs):
        self.bridge = bridge
        self.port = port
        self.token = token
        super().__init__(*args, **kwargs)

    def do_GET(self):
        if not self._trusted_host():
            return self.send_error(403)
        token, route = self._route()
        if route is not None:
            if not self._authorized(token):
                return self.send_error(403)
            if route == "proxy":
                return self._proxy(urllib.parse.urlsplit(self.path).query)
            return self.send_error(405)
        if self._is_index():
            if not self._same_origin():  # other websites must not open the editor
                return self.send_error(403)
            return self._index()
        return super().do_GET()

    def do_HEAD(self):
        if not self._trusted_host():
            return self.send_error(403)
        return super().do_HEAD()

    def do_POST(self):
        if not self._trusted_host():
            return self.send_error(403)
        length = self.headers.get("Content-Length", "0")
        if not (length.isascii() and length.isdigit()) or int(length) > MAX_POST_BYTES:
            return self.send_error(400)
        body = self.rfile.read(int(length))  # read even when dropped, so a kept-alive connection stays in sync
        token, route = self._route()
        if route is not None and not self._authorized(token):
            return self.send_error(403)
        if route in (None, "proxy"):
            # The page's usage telemetry posts to its own URL or, through the proxy, to Roland; it goes nowhere.
            self.send_response(204)
            self.end_headers()
            return None
        if route == "log":
            print(f"[js] {body.decode(errors='replace')[:MAX_LOG_CHARS]!r}")  # repr: the page cannot forge log lines
            return self._reply("")
        if not COMMAND_ROUTE.fullmatch(route):
            return self.send_error(404)
        if self.headers.get_content_type() != "application/json":  # a cross-site form cannot send this unasked
            return self.send_error(415)
        try:
            args = command_args(body)
        except (ValueError, RecursionError) as error:  # JSONDecodeError is a ValueError; deep nesting recurses
            return self._reply(str(error), status=400)
        return self._call(route[2:], args)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "frame-ancestors 'none'")
        super().end_headers()

    def log_request(self, code="-", size="-"):
        # Successes are noise and a failing command already printed why.
        if not str(code).startswith(("2", "3", "500")):
            self.log_message('"%s" %s %s', self._redacted(self.requestline), code, size)  # control chars escaped

    def _redacted(self, text):
        """The token, in any percent-encoded spelling and anywhere in the request line, kept out of the log."""
        while (decoded := urllib.parse.unquote(text)) != text:
            text = decoded
        return text.replace(self.token, "<token>")

    def _route(self):
        """(token, route) for the bridge's routes; route is None for static files."""
        token, slash, route = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)[1:].partition("/")
        if not slash:
            token, route = "", token  # a bridge route without a token
        if not (route.startswith("$$") or route in BRIDGE_ROUTES):
            return None, None
        return token, route

    def _is_index(self):
        """Any spelling of the page itself (`/`, `/./`, `/%69ndex.html`…), so none of them skips the origin check."""
        target = Path(self.translate_path(self.path))
        target = target / "index.html" if target.is_dir() else target
        return target.resolve() == (Path(self.directory) / "index.html").resolve()

    def _authorized(self, token):
        """The per-launch token, compared as bytes (compare_digest refuses non-ASCII str), from this page only."""
        return hmac.compare_digest(token.encode(), self.token.encode()) and self._same_origin()

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
        return self._reply(body, content_type, status)

    def _call(self, command, args):
        try:
            result = json.dumps(self.bridge.dispatch(command, args))
        except Exception as error:  # the page script throws the message as an Error
            print(f"[bts] $${command} failed: {error!r}")
            return self._reply(str(error), status=500)
        return self._reply(result, "application/json")

    def _index(self):
        html = (Path(self.directory) / "index.html").read_text(encoding="utf-8")
        if NATIVE_SCRIPT_TAG not in html:
            print("[bts] index.html no longer loads js/lib/native.js; unsupported app version")
            return self._reply(UNSUPPORTED_PAGE, "text/html; charset=utf-8", 500)
        script = PRE_NATIVE % {"token": self.token, "commands": json.dumps(self.bridge.commands)}
        html = html.replace(NATIVE_SCRIPT_TAG, script + NATIVE_SCRIPT_TAG)
        return self._reply(html, "text/html; charset=utf-8")

    def _reply(self, body, content_type="text/plain; charset=utf-8", status=200):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _trusted_host(self):
        """Rejects DNS-rebinding requests: only loopback host names may reach the backend."""
        return self.headers.get("Host") in self._hosts()

    def _hosts(self):
        return {f"{name}:{self.port}" for name in ("localhost", "127.0.0.1", "[::1]")}

    def _same_origin(self):
        """Keeps other web pages in the user's browser from driving the bridge or opening the editor."""
        origin_ok = self.headers.get("Origin") in {None, *(f"http://{host}" for host in self._hosts())}
        return origin_ok and self.headers.get("Sec-Fetch-Site") in (None, "same-origin", "none")


class IPv6Server(ThreadingHTTPServer):
    address_family = socket.AF_INET6


def _bind():
    """Both loopback addresses on one port: the window opens `localhost`, which WebKit may resolve to either."""
    for _ in range(10):
        servers = [ThreadingHTTPServer(("127.0.0.1", 0), None)]
        port = servers[0].server_address[1]
        try:
            servers.append(IPv6Server(("::1", port), None))
        except OSError as error:
            if error.errno == errno.EADDRINUSE:  # another process holds [::1]:port and would get the page
                servers[0].server_close()
                continue
            print(f"[bts] IPv6 loopback unavailable ({error}); localhost must resolve to 127.0.0.1")
        return port, servers
    raise OSError("no loopback port is free on both IPv4 and IPv6")


def start(html_dir, data_dir):
    """Serves the web app and the bridge on loopback. Returns (port, bridge)."""
    bridge = Bridge(data_dir)
    port, servers = _bind()
    token = secrets.token_urlsafe(24)
    handler = functools.partial(Handler, bridge=bridge, port=port, token=token, directory=os.fspath(html_dir))
    for server in servers:
        server.RequestHandlerClass = handler
        threading.Thread(target=server.serve_forever, daemon=True).start()
    return port, bridge
