"""Resource integrity and non-overwrite checks; no network or actual model required."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

script = Path(__file__).resolve().parents[2] / "scripts/fetch_aircraft_model.py"
spec = importlib.util.spec_from_file_location("aircraft_installer", script)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.content = b"model fixture\0"*100
        revision = "a"*40
        self.metadata = dict(file="AircraftParts.onnx", bytes=len(self.content), sha256=hashlib.sha256(self.content).hexdigest(),
                             revision=revision, url=f"https://huggingface.co/example/model/resolve/{revision}/model.onnx")
        self.manifest()

    def manifest(self):
        (self.root/"manifest.json").write_text(json.dumps(self.metadata), encoding="utf-8")

    def fake_opener(self, content):
        class Response(io.BytesIO):
            def geturl(self):
                return "https://model-cdn.example/weights"
        return lambda request, timeout: Response(content)

    def assert_no_partial(self):
        self.assertEqual(list(self.root.glob("*.part")), [])

    def test_local_install_checks_data_and_preserves_original_source_and_valid_destination(self):
        source = self.root/"uploaded.onnx"
        source.write_bytes(self.content)
        self.assertTrue(installer.install(self.root, source))
        self.assertEqual(source.read_bytes(), self.content)
        with patch.object(installer, 'urlopen', side_effect=AssertionError('Unexpected network')):
            self.assertFalse(installer.install(self.root, opener=lambda *a, **k: self.fail('Unexpected network')))
        self.assertEqual((self.root/self.metadata['file']).read_bytes(), self.content)
        if os.name != 'nt':
            self.assertEqual((self.root/self.metadata['file']).stat().st_mode & 0o777, 0o644)
        self.assert_no_partial()

    def test_existing_invalid_file_is_never_overwritten(self):
        target = self.root/self.metadata['file'];target.write_bytes(b"old resource")
        with self.assertRaises(installer.InstallError):
            installer.install(self.root, opener=lambda *a, **k: self.fail('Unexpected network'))
        self.assertEqual(target.read_bytes(), b"old resource")
        self.assert_no_partial()

    def test_truncated_oversized_and_corrupt_downloads_do_not_publish_or_leave_partial(self):
        for content in (self.content[:-1],self.content+b"extra",b"x"*len(self.content)):
            with self.subTest(length=len(content)), self.assertRaises(installer.InstallError):
                installer.install(self.root, opener=self.fake_opener(content))
            self.assertFalse((self.root/self.metadata['file']).exists())
            self.assert_no_partial()

    def test_complete_download_and_concurrent_valid_install_are_safe(self):
        target = self.root/self.metadata['file']
        def concurrent(source, destination):
            Path(destination).write_bytes(self.content)
            raise FileExistsError()
        with patch.object(installer.os, 'link', side_effect=concurrent):
            self.assertFalse(installer.install(self.root, opener=self.fake_opener(self.content)))
        self.assertEqual(target.read_bytes(), self.content)
        self.assert_no_partial()

    def test_invalid_manifest_and_insecure_redirect_do_not_install(self):
        for key, value in [('file','../other.onnx'),('url','http://example.com/model.onnx'),('bytes',True)]:
            original = self.metadata[key];self.metadata[key] = value;self.manifest()
            with self.assertRaises(installer.InstallError):
                installer.install(self.root, opener=lambda *a, **k: self.fail('Unexpected network'))
            self.metadata[key] = original
        self.manifest()
        class Insecure(io.BytesIO):
            def geturl(self):return 'http://example.com/model.onnx'
        with self.assertRaises(installer.InstallError):
            installer.install(self.root, opener=lambda *a, **k: Insecure(self.content))
        self.assert_no_partial()


if __name__ == '__main__':
    unittest.main()
