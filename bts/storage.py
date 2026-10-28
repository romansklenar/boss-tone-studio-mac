"""The page's `app.storage2`: one file per key, shared by the bridge and the Librarian import."""

import os
import tempfile
import urllib.parse
from pathlib import Path


def write_atomically(path, text):
    """A crash mid-write must not truncate a file such as ID_LIST, which would make the whole Librarian look empty."""
    path = Path(path)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
    with os.fdopen(descriptor, "w", encoding="utf-8") as file:
        file.write(text)
    os.replace(temporary, path)


def read(path):
    """None when the file does not exist."""
    path = Path(path)
    return path.read_text(encoding="utf-8") if path.is_file() else None


class Storage2:
    def __init__(self, data_dir):
        self.directory = Path(data_dir) / "storage2"
        self.directory.mkdir(parents=True, exist_ok=True)

    def read(self, key):
        return read(self._path(key))

    def write(self, key, value):
        """An empty value deletes the key, as the page expects."""
        if value:
            write_atomically(self._path(key), value)
        else:
            self._path(key).unlink(missing_ok=True)

    def _path(self, key):
        name = urllib.parse.quote(str(key), safe="")
        if name in ("", ".", ".."):
            raise ValueError(f"invalid storage key {key!r}")
        return self.directory / name
