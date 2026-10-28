import tempfile
import unittest
from pathlib import Path
from unittest import mock

from bts import __main__ as app


class DataDirLockTest(unittest.TestCase):
    """One process per data folder, so `make roland-import` cannot run under an open app, nor two apps side by side."""

    def test_the_folder_is_locked_until_its_holder_closes_it(self):
        with mock.patch.object(app, "LOCK_FILE", Path(tempfile.mkdtemp()) / "data/app.lock"):
            first = app.lock_data_dir()
            self.assertIsNotNone(first)
            self.assertIsNone(app.lock_data_dir())
            first.close()
            again = app.lock_data_dir()
            self.assertIsNotNone(again)
            again.close()


if __name__ == "__main__":
    unittest.main()
