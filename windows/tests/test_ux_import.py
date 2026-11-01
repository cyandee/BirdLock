import os
os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
import json, tempfile, time, unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from PySide6.QtCore import Qt, QEvent
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication
from birdlock.app.lens_picker import SearchableLensCombo
from birdlock.app.video_import import VideoImportDialog
from birdlock.core import lens_catalog
from birdlock.core.camera_metadata import CameraMetadata
from birdlock.core.video_import import VideoInfo, selection
from birdlock.core.video_source import original_path
from birdlock.core.frames import SourceFrame

class ImportUXTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app=QApplication.instance() or QApplication([])
        cls.catalog=lens_catalog.entries()
    def dispose(self, widget):
        widget.close();widget.deleteLater();self.app.sendPostedEvents(None,QEvent.DeferredDelete);self.app.processEvents()
    def combo(self):
        c=SearchableLensCombo();c.set_entries(self.catalog);c.show()
        def select(path):
            entry=next((e for e in self.catalog if str(e.url)==path),None)
            c.set_selection(path,entry.title if entry else '')
        c.valueSelected.connect(select)
        self.addCleanup(self.dispose,c);return c
    def test_search_enter_commits_real_profile_and_clear_removes_it(self):
        c=self.combo();c.lineEdit().setText('索尼 FX3');c.lineEdit().textEdited.emit('索尼 FX3')
        self.assertTrue(c.searching);self.assertGreater(c.matches.rowCount(),1)
        self.assertFalse(c.selected_path)
        QTest.keyClick(c.lineEdit(),Qt.Key_Return)
        self.assertIn('FX3',c.selected_title);self.assertFalse(c.searching)
        c.lineEdit().clear();c.lineEdit().textEdited.emit('')
        self.assertFalse(c.selected_path);self.assertFalse(c.searching)
        c.lineEdit().setText("Sony");c.lineEdit().textEdited.emit("Sony")
        c.lineEdit().clear();c.lineEdit().textEdited.emit("")
        self.assertFalse(c.completer().popup().isVisible())
    def test_popup_keyboard_uses_highlight_and_escape_restores_choice(self):
        c=self.combo();c.lineEdit().setText('Sony FX3');c.lineEdit().textEdited.emit('Sony FX3')
        popup=c.completer().popup();index=c.completer().completionModel().index(1,0)
        expected=index.data(Qt.UserRole);self.assertTrue(expected)
        popup.setCurrentIndex(index);QTest.keyClick(popup,Qt.Key_Return)
        self.assertEqual(c.selected_path,expected)
        c.lineEdit().setText('Nikon');c.lineEdit().textEdited.emit('Nikon')
        QTest.keyClick(popup,Qt.Key_Escape)
        self.assertFalse(c.searching);self.assertEqual(c.selected_path,expected)
    def test_no_results_cannot_commit_or_overwrite_previous_choice(self):
        c=self.combo();entry=self.catalog[0];c.set_selection(str(entry.url),entry.title)
        c.lineEdit().setText('not-a-camera-xyz');c.lineEdit().textEdited.emit('not-a-camera-xyz')
        QTest.keyClick(c.lineEdit(),Qt.Key_Return)
        self.assertEqual(c.selected_path,str(entry.url));self.assertTrue(c.searching)
        QTest.keyClick(c.lineEdit(),Qt.Key_Escape)
        self.assertEqual(c.currentText(),entry.title);self.assertFalse(c.searching)
    def test_external_profile_survives_search_escape(self):
        c=self.combo();c.set_selection('/test/custom.json','My calibrated lens')
        c.lineEdit().setText('Sony');c.lineEdit().textEdited.emit('Sony')
        QTest.keyClick(c.lineEdit(),Qt.Key_Escape)
        self.assertEqual(c.selected_path,'/test/custom.json');self.assertEqual(c.currentText(),'My calibrated lens')
    def dialog(self):
        info=VideoInfo(3840,2160,30.,10.)
        match=SimpleNamespace(metadata=SimpleNamespace(display_name='Sony test'),selected_url=None,selected=None,message='')
        with patch('birdlock.app.video_import.probe',return_value=info),patch('birdlock.app.video_import.lens_catalog.detect',return_value=match):
            d=VideoImportDialog('test.mp4',SimpleNamespace(import_video=lambda *a:None))
            end=time.monotonic()+3
            while d.info is None and time.monotonic()<end:self.app.processEvents();time.sleep(.005)
        self.addCleanup(self.dispose,d);self.assertIsNotNone(d.info);return d
    def test_invalid_start_disables_import_and_preview_clamps_end(self):
        d=self.dialog();d.start.setValue(11);self.assertFalse(d.go.isEnabled())
        d.start.setValue(9);self.assertTrue(d.go.isEnabled());self.assertIn('9.00–10.00',d.clip_summary.text())
        d.seconds.setValue(1);d.fps.setValue(60);self.assertIn('30 帧',d.clip_summary.text())
    def test_late_automatic_match_preserves_explicit_selection(self):
        d=self.dialog();entry=self.catalog[0];d.choose_builtin(str(entry.url))
        expected=d.profile;self.assertIsNotNone(expected)
        d.apply_match(SimpleNamespace(metadata=SimpleNamespace(display_name='Updated identity'),selected_url=None,selected=None,message='No exact match'),automatic=True)
        self.assertEqual(d.profile,expected);self.assertEqual(d.catalog.selected_path,expected)
    def test_shared_limits_before_decoding(self):
        info=VideoInfo(1920,1080,24.,200.)
        self.assertEqual(selection(info,199,10,60),(1.,24.,24))
        for start,seconds,fps in [(200,1,30),(0,121,30),(-1,1,30),(0,1,float('nan')),(0,120,60)]:
            if seconds==120 and fps==60:info=VideoInfo(1920,1080,60.,200.)
            with self.assertRaises(ValueError):selection(info,start,seconds,fps)
    def test_silent_video_export_uses_original_name(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);frame=SourceFrame(0,str(root/'video-000000.jpg'),64,48)
            (root/'video-source.json').write_text(json.dumps(dict(version=1,sourcePath='/user/videos/C0320.MP4',fps=30.,count=1,audioFile=None)))
            self.assertEqual(original_path([frame]),'/user/videos/C0320.MP4')
            self.assertIsNone(original_path([]))
