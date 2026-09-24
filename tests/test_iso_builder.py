import importlib.util
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import pycdlib


SPEC = importlib.util.spec_from_file_location(
    "limiar_iso_builder", Path(__file__).resolve().parents[1] / "scripts/windows/build_iso.py"
)
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


class IsoBuilderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "payload"
        self.source.mkdir()
        (self.source / "Autounattend.xml").write_bytes(b"<unattend>fixture</unattend>")
        self.output = self.root / "payload.iso"

    def tearDown(self):
        self.temporary.cleanup()

    def test_udf_preserves_windows_names_and_contents(self):
        directory = self.source / "Long Windows directory name"
        directory.mkdir()
        (directory / "Driver With Spaces.dll").write_bytes(b"driver fixture")
        report = BUILDER.build(self.source, self.output, "LIMIAR_TEST")
        self.assertEqual(report["files"], 2)
        iso = pycdlib.PyCdlib()
        try:
            iso.open(str(self.output))
            data = io.BytesIO()
            iso.get_file_from_iso_fp(data, udf_path="/Long Windows directory name/Driver With Spaces.dll")
            self.assertEqual(data.getvalue(), b"driver fixture")
        finally:
            iso.close()

    def test_existing_output_is_preserved(self):
        self.output.write_bytes(b"existing image")
        with self.assertRaises(ValueError):
            BUILDER.build(self.source, self.output, "LIMIAR_TEST")
        self.assertEqual(self.output.read_bytes(), b"existing image")

    def test_output_inside_input_tree_is_rejected(self):
        with self.assertRaises(ValueError):
            BUILDER.build(self.source, self.source / "recursive.iso", "LIMIAR_TEST")

    def test_invalid_label_is_rejected_before_writing(self):
        for label in ["", "../escape", "A" * 33, "\u00e9"]:
            with self.subTest(label=label), self.assertRaises(ValueError):
                BUILDER.build(self.source, self.output, label)
            self.assertFalse(self.output.exists())

    def test_failed_writer_does_not_publish_a_partial_iso(self):
        with patch.object(pycdlib.PyCdlib, "write_fp", side_effect=OSError("fixture failure")):
            with self.assertRaises(OSError):
                BUILDER.build(self.source, self.output, "LIMIAR_TEST")
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.root.glob(".limiar-iso-*")), [])

    @unittest.skipIf(os.name == "nt", "unprivileged symlink creation differs on Windows")
    def test_links_do_not_include_external_files(self):
        outside = self.root / "private"
        outside.write_bytes(b"must not be included")
        (self.source / "link").symlink_to(outside)
        with self.assertRaises(ValueError):
            BUILDER.build(self.source, self.output, "LIMIAR_TEST")
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
