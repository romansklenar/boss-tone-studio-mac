"""Brings the Librarian (livesets with patches) over from Roland's own BOSS TONE STUDIO for KATANA MkII.

Roland's app keeps `$native.app.storage2` in its NSUserDefaults plist under the same keys the page uses here
(`ID_LIST`, `CONFIRM_FLAG`, one numeric key per liveset), so values are copied verbatim. The plist is only read.
"""

import json
import plistlib
from pathlib import Path

from bts.storage import Storage2

ROLAND_PREFS = Path.home() / "Library/Preferences/jp.co.roland.BOSS-TONE-STUDIO-for-KATANA-MkII.plist"
MARKER = "roland-librarian-imported"
MAX_LIVESETS = 50  # librarianCommonInfo.maxLivesetNum; liveset IDs live in 0..49


def import_once(data_dir, prefs=ROLAND_PREFS):
    """Imports on the first launch that finds Roland's plist, so former users open straight into their library."""
    marker = Path(data_dir) / MARKER
    if marker.exists() or not prefs.exists():
        return
    marker.parent.mkdir(parents=True, exist_ok=True)
    try:
        summary = import_librarian(data_dir, prefs)
    except Exception as error:  # an unreadable plist must not keep the app from starting
        summary = f"Import failed ({error!r}); retry with `make import-roland`"
        print(f"[bts] {summary}")
    marker.write_text(summary + "\n", encoding="utf-8")


def import_librarian(data_dir, prefs=ROLAND_PREFS):
    """Appends Roland's livesets to this app's Librarian; skips ones already here, so re-running is harmless."""
    roland = plistlib.loads(prefs.read_bytes())
    store = Storage2(data_dir)

    raw_ids = store.read("ID_LIST")
    ids = json.loads(raw_ids)["list"] if raw_ids else []
    existing = {store.read(i) for i in ids}
    free = [i for i in range(MAX_LIVESETS) if i not in ids]
    imported, skipped = [], []
    for roland_id in json.loads(roland.get("ID_LIST") or '{"list":[]}')["list"]:
        value = roland.get(str(roland_id))
        if not value or value in existing:
            continue
        if not free:
            skipped.append(roland_id)
            continue
        new_id = roland_id if roland_id in free else free[0]
        free.remove(new_id)
        store.write(new_id, value)
        existing.add(value)
        imported.append(new_id)

    if imported:
        # Roland's order first: that is the library the user knows; anything made here follows it.
        store.write("ID_LIST", json.dumps({"list": imported + ids}, separators=(",", ":")))
    if store.read("CONFIRM_FLAG") is None and roland.get("CONFIRM_FLAG"):
        store.write("CONFIRM_FLAG", roland["CONFIRM_FLAG"])

    summary = f"Imported {len(imported)} livesets from {prefs}"
    if skipped:
        summary += f"; {len(skipped)} skipped, the Librarian holds at most {MAX_LIVESETS}"
    print(f"[bts] {summary}")
    return summary
