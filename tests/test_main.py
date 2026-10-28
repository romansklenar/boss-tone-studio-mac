import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from bts import __main__ as app


class AppRunningTest(unittest.TestCase):
    """`make import-roland` must not run under an open app, whose Librarian would overwrite the import."""

    def check(self, content):
        pid_file = Path(tempfile.mkdtemp()) / "app.pid"
        if content is not None:
            pid_file.write_text(content)
        with mock.patch.object(app, "PID_FILE", pid_file):
            return app.app_running()

    def test_another_live_process_counts_as_running(self):
        self.assertTrue(self.check(str(os.getppid())))

    def test_this_process_a_dead_pid_or_no_file_do_not(self):
        for content in (str(os.getpid()), "999999", "garbage", None):
            with self.subTest(content=content):
                self.assertFalse(self.check(content))


if __name__ == "__main__":
    unittest.main()
