"""Runs Roland's BOSS TONE STUDIO for KATANA MkII web app natively on Apple Silicon.

python -m bts             # app window (WKWebView via pywebview)
python -m bts --browser   # backend only; open the printed URL in a browser (no file dialogs)
python -m bts --import-roland   # (re)import the Librarian from Roland's app, then exit
"""

import fcntl
import os
import sys
import threading
from pathlib import Path

from bts import roland_import, server

APP_NAME = "BOSS TONE STUDIO for KATANA MkII (Apple Silicon)"  # also the bundle name (packaging/app.spec, Makefile)
DATA_DIR = Path(os.environ.get("BTS_DATA_DIR", Path.home() / "Library/Application Support" / APP_NAME))
LOCK_FILE = DATA_DIR / "app.lock"
ROLAND_HTML = Path("/Applications/BOSS/KATANA MkII/BOSS TONE STUDIO for KATANA MkII.app/Contents/Resources/html")


def html_dir():
    """Roland's web app: BTS_HTML_DIR, else bundled in the .app, else fetched into the checkout, else installed."""
    if os.environ.get("BTS_HTML_DIR"):
        return Path(os.environ["BTS_HTML_DIR"])
    candidates = [Path(__file__).resolve().parent.parent / "build/roland/html", ROLAND_HTML]
    if hasattr(sys, "_MEIPASS"):  # inside the PyInstaller bundle
        candidates.insert(0, Path(sys._MEIPASS) / "roland-html")
    return next((c for c in candidates if (c / "index.html").is_file()), candidates[0])


def lock_data_dir():
    """One process per data folder: another one's in-memory Librarian would overwrite this one's writes or an import.

    Returns the locked file, to be kept open for the process's lifetime (the OS releases it on exit), or None.
    """
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    lock = LOCK_FILE.open("w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        return None
    return lock


def main():
    lock = lock_data_dir()  # stays open, and so locked, until the process exits
    if "--import-roland" in sys.argv:
        if not lock:
            sys.exit("Quit the app first: it would overwrite the imported Librarian with the one it has open.")
        if not roland_import.ROLAND_PREFS.exists():
            sys.exit(f"Roland's settings not found in {roland_import.ROLAND_PREFS}")
        roland_import.import_librarian(DATA_DIR)
        return

    if not lock:
        sys.exit(f"Another instance already uses {DATA_DIR}.")
    html = html_dir()
    if not (html / "index.html").is_file():
        sys.exit(f"Roland's web app not found in {html}; run `make roland-assets` or set BTS_HTML_DIR.")
    roland_import.import_once(DATA_DIR)  # before the page loads, so it opens on the imported Librarian

    port, bridge = server.start(html, DATA_DIR)
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
