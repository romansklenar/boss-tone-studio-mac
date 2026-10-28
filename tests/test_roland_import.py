import json
import plistlib
import tempfile
import unittest
from pathlib import Path

from bts import roland_import


def liveset(name):
    # Roland's page stores JSON.stringify(liveset), which is itself a JSON string.
    return json.dumps(json.dumps({"name": name, "formatRev": "0002", "device": "KATANA MkII", "data": [[]]}))


class RolandImportTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.data_dir = self.tmp / "data"
        self.storage2 = self.data_dir / "storage2"
        self.prefs = self.tmp / "roland.plist"
        self.write_prefs(
            {
                "ID_LIST": '{"list":[2,1]}',
                "1": liveset("Foo"),
                "2": liveset("Bar"),
                "0": "",
                "CONFIRM_FLAG": "true",
                "pref": '{"guid":"x"}',
            }
        )

    def write_prefs(self, values):
        self.prefs.write_bytes(plistlib.dumps(values))

    def read(self, key):
        return (self.storage2 / key).read_text()

    def ids(self):
        return json.loads(self.read("ID_LIST"))["list"]

    def test_fresh_library_matches_roland_order_and_values(self):
        roland_import.import_librarian(self.data_dir, self.prefs)

        self.assertEqual(self.ids(), [2, 1])
        self.assertEqual(self.read("1"), liveset("Foo"))
        self.assertEqual(self.read("CONFIRM_FLAG"), "true")
        self.assertFalse((self.storage2 / "pref").exists())

    def test_reimport_adds_nothing(self):
        roland_import.import_librarian(self.data_dir, self.prefs)
        summary = roland_import.import_librarian(self.data_dir, self.prefs)

        self.assertIn("Imported 0 livesets", summary)
        self.assertEqual(self.ids(), [2, 1])

    def test_colliding_id_moves_to_a_free_one_and_keeps_local_livesets(self):
        self.storage2.mkdir(parents=True)
        (self.storage2 / "0").write_text(liveset("LIVESET 1"))
        (self.storage2 / "1").write_text(liveset("Mine"))
        (self.storage2 / "ID_LIST").write_text('{"list":[0,1]}')

        roland_import.import_librarian(self.data_dir, self.prefs)

        self.assertEqual(self.ids(), [2, 3, 0, 1])
        self.assertEqual(self.read("1"), liveset("Mine"))
        self.assertEqual(self.read("3"), liveset("Foo"))

    def test_stops_at_the_librarian_limit(self):
        self.storage2.mkdir(parents=True)
        for i in range(49):
            (self.storage2 / str(i)).write_text(liveset(f"L{i}"))
        (self.storage2 / "ID_LIST").write_text(json.dumps({"list": list(range(49))}))

        summary = roland_import.import_librarian(self.data_dir, self.prefs)

        self.assertEqual(len(self.ids()), 50)
        self.assertIn("1 skipped", summary)

    def test_import_once_runs_a_single_time(self):
        roland_import.import_once(self.data_dir, self.prefs)
        self.write_prefs({"ID_LIST": '{"list":[5]}', "5": liveset("Later")})
        roland_import.import_once(self.data_dir, self.prefs)

        self.assertEqual(self.ids(), [2, 1])

    def test_duplicates_in_rolands_list_are_imported_once(self):
        self.write_prefs({"ID_LIST": '{"list":[1,2]}', "1": liveset("Same"), "2": liveset("Same")})
        roland_import.import_librarian(self.data_dir, self.prefs)

        self.assertEqual(self.ids(), [1])

    def test_import_once_survives_an_unreadable_plist(self):
        self.prefs.write_bytes(b"not a plist")
        roland_import.import_once(self.data_dir, self.prefs)

        self.assertIn("Import failed", (self.data_dir / roland_import.MARKER).read_text())

    def test_import_once_waits_for_roland_settings(self):
        roland_import.import_once(self.data_dir, self.tmp / "missing.plist")

        self.assertFalse((self.data_dir / roland_import.MARKER).exists())


if __name__ == "__main__":
    unittest.main()
