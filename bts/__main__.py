"""Runs Roland's BOSS TONE STUDIO for KATANA MkII web app natively on Apple Silicon.

python -m bts             # app window (WKWebView via pywebview)
python -m bts --browser   # backend only; open the printed URL in a browser (no file dialogs)
python -m bts --import-roland   # (re)import the Librarian from Roland's app, then exit
"""

import atexit
import os
import sys
import threading
from pathlib import Path

from bts import roland_import, server

APP_NAME = "BOSS TONE STUDIO for KATANA MkII (Apple Silicon)"  # also the bundle name (packaging/app.spec, Makefile)
DATA_DIR = Path(os.environ.get("BTS_DATA_DIR", Path.home() / "Library/Application Support" / APP_NAME))
PID_FILE = DATA_DIR / "app.pid"
ROLAND_HTML = Path("/Applications/BOSS/KATANA MkII/BOSS TONE STUDIO for KATANA MkII.app/Contents/Resources/html")


def html_dir():
    """Roland's web app: BTS_HTML_DIR, else bundled in the .app, else fetched into the checkout, else installed."""
    if os.environ.get("BTS_HTML_DIR"):
        return Path(os.environ["BTS_HTML_DIR"])
    candidates = [Path(__file__).resolve().parent.parent / "build/roland/html", ROLAND_HTML]
    if hasattr(sys, "_MEIPASS"):  # inside the PyInstaller bundle
        candidates.insert(0, Path(sys._MEIPASS) / "roland-html")
    return next((c for c in candidates if (c / "index.html").is_file()), candidates[0])


def app_running():
    """True while another instance serves this data folder; its in-memory Librarian would overwrite an import."""
    try:
        pid = int(PID_FILE.read_text())
        os.kill(pid, 0)
    except (OSError, ValueError):
        return False
    return pid != os.getpid()


def main():
    if "--import-roland" in sys.argv:
        if app_running():
            sys.exit("Quit the app first: it would overwrite the imported Librarian with the one it has open.")
        if not roland_import.ROLAND_PREFS.exists():
            sys.exit(f"Roland's settings not found in {roland_import.ROLAND_PREFS}")
        roland_import.import_librarian(DATA_DIR)
        return

    html = html_dir()
    if not (html / "index.html").is_file():
        sys.exit(f"Roland's web app not found in {html}; run `make roland-assets` or set BTS_HTML_DIR.")
    roland_import.import_once(DATA_DIR)  # before the page loads, so it opens on the imported Librarian

    port, bridge = server.start(html, DATA_DIR)
    PID_FILE.write_text(str(os.getpid()))
    atexit.register(PID_FILE.unlink, missing_ok=True)
    url = f"http://localhost:{port}/index.html"

    if "--browser" in sys.argv:
        print(f"Serving {html}\nOpen {url}", flush=True)
        threading.Event().wait()

    import webview

    bridge.window = webview.create_window(APP_NAME, url, width=1280, height=800, min_size=(1160, 700))
    bridge.window.events.closing += bridge.on_closing
    webview.start(gui="cocoa", private_mode=False, storage_path=str(DATA_DIR / "webview"))


if __name__ == "__main__":
    main()
