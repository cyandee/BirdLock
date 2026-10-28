"""Updater UI and startup handshake, isolated from user settings and network."""
import json,os,sys,tempfile,unittest,uuid
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch,Mock
os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
from PySide6.QtWidgets import QApplication
from PySide6.QtCore import QProcess
from birdlock.app import updates

class UpdateUITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.app=QApplication.instance() or QApplication([])
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        (self.root/'updates').mkdir();(self.root/'updates/config.json').write_text('{"enabled":false}')
        self.patches=[patch.object(updates,'data_dir',return_value=self.root),patch.object(updates,'resource_dir',return_value=self.root),patch.object(updates,'update_root',return_value=self.root/'sessions')]
        for p in self.patches:p.start()
        self.dialog=updates.UpdateDialog(SimpleNamespace(export_running=False,phase='ready'))
        self.app.processEvents()
    def tearDown(self):
        self.dialog.close();self.dialog.deleteLater();self.app.processEvents()
        for p in self.patches:p.stop()
        self.tmp.cleanup()
    def test_disabled_and_busy_do_not_launch(self):
        self.assertIn('尚未启用',self.dialog.message.text());self.assertEqual(self.dialog.query.state(),QProcess.NotRunning)
        self.dialog.state.export_running=True;self.dialog.check();self.assertIn('正在分析或导出',self.dialog.message.text())
    def test_bad_preferences_reset_and_beta_persist(self):
        (self.root/'updates.json').write_text('[]');self.assertFalse(updates.preferences()['automatic'])
        self.dialog.beta.setChecked(False);self.assertFalse(json.loads((self.root/'updates.json').read_text())['beta'])
    def test_verified_check_result_and_failure_controls(self):
        self.dialog.query=Mock()
        self.dialog.query.readAllStandardOutput.return_value=b'{"available":true,"version":"1.5.1","notes":"notes","channel":"beta"}'
        self.dialog.checked(0);self.assertTrue(self.dialog.install.isEnabled());self.assertIn('1.5.1',self.dialog.message.text())
        self.dialog.query.readAllStandardError.return_value=b'invalid signature';self.dialog.checked(1);self.assertIn('检查更新失败',self.dialog.message.text())
    def test_health_path_validation_and_argument_removal(self):
        session=self.root/'sessions'/uuid.uuid4().hex;session.mkdir(parents=True);health=session/'health'
        with patch.object(sys,'argv',['BirdLock','--update-health',str(health)]):
            updates.startup_health();self.assertEqual(sys.argv,['BirdLock'])
        if os.name=='nt':self.assertEqual(health.read_text(),updates.VERSION)
        outside=self.root/'health'
        with patch.object(sys,'argv',['BirdLock','--update-health',str(outside)]):updates.startup_health()
        self.assertFalse(outside.exists())
