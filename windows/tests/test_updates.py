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

MIRROR='https://3rd.0x01.page/birdlock/update-api/'
DEFAULTS=[{'id':'github','name':'GitHub'},{'name':'镜像','url':MIRROR}]

class UpdateSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.app=QApplication.instance() or QApplication([])
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);(self.root/'updates').mkdir()
        (self.root/'updates/config.json').write_text(json.dumps({'enabled':False,'sources':DEFAULTS}),encoding='utf-8')
        self.patches=[patch.object(updates,'data_dir',return_value=self.root),patch.object(updates,'resource_dir',return_value=self.root)]
        for p in self.patches:p.start()
    def tearDown(self):
        for p in self.patches:p.stop()
        self.tmp.cleanup()
    def test_source_url_rules(self):
        self.assertEqual(updates.source_base(' https://Mirror.Test/a/b '),'https://mirror.test/a/b/')
        self.assertEqual(updates.source_base(MIRROR),MIRROR)
        for bad in ('http://mirror.test/','https://u:p@mirror.test/','https://mirror.test/?x=1','https://mirror.test/#a','mirror.test','https:///path'):
            with self.assertRaises(ValueError,msg=bad):updates.source_base(bad)
    def test_defaults_and_saved_order(self):
        self.assertEqual(updates.default_sources(),DEFAULTS)
        self.assertEqual(updates.default_sources({}),[{'id':'github','name':'GitHub'}])
        self.assertIsNone(updates.preferences()['sources'])
        saved=[{'name':'镜像','url':MIRROR},{'url':'http://insecure.test/'},'junk',{'id':'github'},{'name':'dup','url':MIRROR.rstrip('/')}]
        (self.root/'updates.json').write_text(json.dumps({'sources':saved}))
        self.assertEqual(updates.preferences()['sources'],[{'name':'镜像','url':MIRROR},{'id':'github','name':'GitHub'}])
        self.assertEqual(updates.source_arguments(updates.preferences()['sources']),['--source',MIRROR,'--source','github'])
    def test_dialog_reorder_add_remove_and_reset(self):
        d=updates.SourcesDialog(DEFAULTS,DEFAULTS)
        d.list.setCurrentRow(1);d.move(-1);self.assertEqual([s.get('url') for s in d.sources()],[MIRROR,None])
        with patch.object(updates.QInputDialog,'getText',return_value=('https://extra.test/birdlock',True)):d.add()
        self.assertEqual(d.sources()[-1],{'name':'extra.test','url':'https://extra.test/birdlock/'})
        with patch.object(updates.QInputDialog,'getText',return_value=('http://extra.test/',True)),patch.object(updates.QMessageBox,'warning') as warn:d.add()
        warn.assert_called_once();self.assertEqual(len(d.sources()),3)
        d.list.setCurrentRow(0);d.remove();d.remove();self.assertEqual(len(d.sources()),1);self.assertFalse(d.buttons['remove'].isEnabled())
        d.remove();self.assertEqual(len(d.sources()),1)
        d.buttons['reset'].click();self.assertEqual(d.sources(),DEFAULTS);d.deleteLater()
    def test_update_dialog_saves_only_custom_sources(self):
        dialog=updates.UpdateDialog(SimpleNamespace(export_running=False,phase='ready'));self.app.processEvents()
        try:
            custom=[DEFAULTS[1],DEFAULTS[0]]
            with patch.object(updates,'SourcesDialog') as cls:
                cls.return_value.exec.return_value=updates.QDialog.Accepted;cls.return_value.sources.return_value=custom;dialog.edit_sources()
                self.assertEqual(json.loads((self.root/'updates.json').read_text())['sources'],custom);self.assertEqual(dialog.current_sources(),custom)
                cls.return_value.sources.return_value=list(DEFAULTS);dialog.edit_sources()
                self.assertIsNone(json.loads((self.root/'updates.json').read_text())['sources']);self.assertEqual(dialog.current_sources(),DEFAULTS)
            dialog.query=Mock();dialog.query.readAllStandardOutput.return_value=json.dumps({'available':True,'version':'1.11.0','notes':'','channel':'stable','source':'3rd.0x01.page','source_url':MIRROR}).encode()
            dialog.checked(0);self.assertIn('来源：镜像',dialog.message.text())
            dialog.query.readAllStandardOutput.return_value=json.dumps({'available':False,'version':'1.10.0','source':'GitHub','source_url':None}).encode()
            dialog.checked(0);self.assertIn('来源：GitHub',dialog.message.text())
            dialog.query.readAllStandardOutput.return_value=json.dumps({'available':False,'version':'1.10.0','source':'other.test','source_url':'https://other.test/'}).encode()
            dialog.checked(0);self.assertIn('来源：other.test',dialog.message.text())
        finally:dialog.close();dialog.deleteLater();self.app.processEvents()
