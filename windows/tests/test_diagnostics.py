import json, tempfile, unittest, zipfile
from pathlib import Path
from unittest.mock import patch
from birdlock.core.diagnostics import export_bundle, redact

class DiagnosticBundleTests(unittest.TestCase):
    def test_bundle_contains_only_logs_and_system_info_with_private_home_hidden(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            (root/'birdlock.log').write_text('photo='+str(Path.home()/'Pictures/private.jpg')+'\ntoken=secret123')
            (root/'crash.log').write_text('crash stack')
            (root/'settings.json').write_text('{"private":"settings"}')
            (root/'private-photo.jpg').write_bytes(b'photo')
            destination=root/'report.zip'
            with patch('birdlock.core.diagnostics.data_dir',return_value=root),patch('birdlock.core.gpu.list_adapters',return_value=[]):
                export_bundle(destination)
            with zipfile.ZipFile(destination) as z:
                self.assertIn('birdlock.log',z.namelist());self.assertIn('system.json',z.namelist())
                self.assertNotIn('settings.json',z.namelist());self.assertNotIn('private-photo.jpg',z.namelist())
                logs=z.read('birdlock.log').decode()
                self.assertNotIn(str(Path.home()),logs);self.assertNotIn('secret123',logs)
                self.assertIn('version',json.loads(z.read('system.json')))
            self.assertFalse((root/'report.zip.tmp').exists())
    def test_windows_paths_are_hidden(self):
        text=redact('Traceback\nC:\\Users\\person\\Pictures\\photo.jpg\nencoder=libx265')
        self.assertNotIn('person',text);self.assertIn('encoder=libx265',text)
