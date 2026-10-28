import unittest

from bts.server import encode, post_args


class PostArgsTest(unittest.TestCase):
    def test_numeric_liveset_id_arrives_as_a_string(self):
        # The Librarian deletes with storage2(liveset.id, ''), where the ID is a number.
        self.assertEqual(post_args(b'[3, ""]'), ["3", ""])

    def test_empty_body_has_no_arguments(self):
        self.assertEqual(post_args(b""), [])


class EncodeTest(unittest.TestCase):
    def test_types_follow_native_js_decode(self):
        encoded = [encode(None), encode(True), encode(False), encode(7), encode("x")]
        self.assertEqual(encoded, ["v", "b1", "b", "d7", "sx"])


if __name__ == "__main__":
    unittest.main()
