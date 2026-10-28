"""Real Qt values must keep their Enum type after selecting a combobox entry."""
import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
import unittest
from types import SimpleNamespace
from PySide6.QtWidgets import QApplication
from birdlock.app.inspector import Tab
from birdlock.core.settings import VideoCodec, VideoQuality, FrameInterpolation, LoopMode

class ChoiceWidgetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.app=QApplication.instance() or QApplication([])
    def test_all_export_enum_widgets_keep_python_values(self):
        for enum in (VideoCodec, VideoQuality, FrameInterpolation, LoopMode):
            state=SimpleNamespace(settings_changed=lambda *a:None)
            tab=Tab(state);selected=[next(iter(enum))]
            combo=tab.combo(None,'test',[(v.title,v) for v in enum],lambda:selected[0],lambda v:selected.__setitem__(0,v))
            for i in list(range(len(enum)))+list(reversed(range(len(enum)))):
                combo.setCurrentIndex(i)
                self.assertIsInstance(selected[0],enum)
            if enum is VideoCodec:self.assertIn(selected[0].ext,('mov','mp4'))
            if enum is VideoQuality:self.assertGreater(selected[0].bpp,0)
            tab.deleteLater()
    def test_dynamic_entries_preserve_objects_and_ignore_clear_signal(self):
        state=SimpleNamespace(settings_changed=lambda *a:None)
        tab=Tab(state);selected=[VideoCodec.H264];values=[('h264',VideoCodec.H264),('hevc',VideoCodec.HEVC)]
        combo=tab.combo(None,'test',lambda:values,lambda:selected[0],lambda v:selected.__setitem__(0,v))
        combo.setCurrentIndex(1);self.assertIs(selected[0],VideoCodec.HEVC)
        values[:]=[('prores',VideoCodec.PRORES_4444),('h264',VideoCodec.H264)]
        tab.b.refresh();combo.setCurrentIndex(1);combo.setCurrentIndex(0)
        self.assertIs(selected[0],VideoCodec.PRORES_4444)
        combo.clear();self.assertIs(selected[0],VideoCodec.PRORES_4444)
        tab.deleteLater()
