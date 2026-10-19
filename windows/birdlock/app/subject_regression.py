"""Isolated own-app subject transition and real aircraft integration regression."""
import json
import os
from pathlib import Path
import threading
import time
from dataclasses import replace
from unittest.mock import patch

import numpy as np
from PySide6.QtWidgets import QApplication,QCheckBox,QComboBox,QPushButton,QDoubleSpinBox

from .state import AppState
from .main_window import MainWindow
from . import theme
from ..core import frames as F
from ..core.analysis import Cancelled
from ..core.aircraft_analysis import AircraftAnalyzer
from ..core.settings import AspectRatio,FocusMarkColor,VideoCodec
from ..core.exporter import VideoExporter


def main(argv):
    if not os.environ.get('BIRDLOCK_DATA'):
        raise SystemExit('Subject regression requires a disposable BIRDLOCK_DATA directory')
    if len(argv)!=3:raise SystemExit('Usage: --subject-regression bird-photos aircraft-photos output')
    birds,planes,out=argv[0],argv[1],Path(argv[2]);out.mkdir(parents=True,exist_ok=True)
    app=QApplication([]);theme.apply(app);state=AppState();state.device='cpu'
    window=MainWindow(state);window.show()
    def settle(seconds=.45):
        end=time.monotonic()+seconds
        while time.monotonic()<end:app.processEvents();time.sleep(.01)
    def wait(test,limit=240):
        end=time.monotonic()+limit
        while not test():
            app.processEvents()
            if state.phase=='failed':raise RuntimeError(state.message)
            if time.monotonic()>end:raise TimeoutError('Subject operation timed out')
            time.sleep(.01)
    try:
        raw=F.import_frames([birds])[:8];assert len(raw)==8
        with patch('birdlock.core.frames.import_frames',return_value=raw):
            state.import_paths([birds]);wait(lambda:state.phase=='ready' and state.job is not None)
        state.composition.anchorX=.31;state.export.focusMark.headColor=FocusMarkColor.ORANGE
        state.set_manual_eye(state.analysis.track.head_center[0]);state.add_closeup();settle()
        previous=state.analysis;previous_key=previous.fingerprint
        started=threading.Event();stopped=threading.Event()
        def held(self,frames,fps,hint=None,progress=None,cancelled=lambda:False,clips=None):
            started.set()
            try:
                while not cancelled():time.sleep(.01)
                raise Cancelled()
            finally:stopped.set()
        with patch.object(AircraftAnalyzer,'analyze',held):
            window.subject_combo.setCurrentIndex(window.subject_combo.findData('aircraft'))
            wait(started.is_set);assert state.analysis is None
            state.cancel_analysis();wait(stopped.is_set);settle()
        assert state.subject=='bird' and state.analysis is previous
        assert state.analysis.manualEye and state.analysis.closeups
        assert state.composition.anchorX==.31 and state.export.focusMark.headColor==FocusMarkColor.ORANGE
        # Clear photos before changing subject; the actual import below exercises two cuts.
        state.frames=[];state.segments=[];state.analysis=None;state.job=None;state.phase='empty'
        window.subject_combo.setCurrentIndex(window.subject_combo.findData('aircraft'));settle()
        raw=F.import_frames([planes]);assert len(raw)>=20
        selected=raw[:4]+raw[16:20]
        selected=[replace(f,id=i,captureTime=(i/30 if i<4 else 10+(i-4)/30)) for i,f in enumerate(selected)]
        with patch('birdlock.core.frames.import_frames',return_value=selected):
            state.import_paths([planes],merge=True);wait(lambda:state.phase=='ready' and state.job is not None)
        assert state.is_aircraft and state.analysis.subject=='aircraft' and len(state.analysis.clips)==2
        assert state.analysis.fingerprint!=previous_key and state.analysis.modelIdentity
        assert int(state.analysis.track.has_data.sum())==8
        assert not state.analysis.track.eye_visible.any() and not state.predicted_frames
        window.inspector.tabbar.setCurrentIndex(2);settle()
        eye=next(x for x in window.findChildren(QCheckBox) if x.text()=='鸟眼框')
        head=next(x for x in window.findChildren(QCheckBox) if x.text()=='机头框')
        assert eye.isHidden() and not head.isHidden()
        choices=window.findChildren(QComboBox)
        assert any(x.count()==1 and x.itemText(0)=='机头' for x in choices)
        assert any(x.text()=='全机留白' for x in window.findChildren(QPushButton))
        state.export.focusMark.headColor=FocusMarkColor.WHITE;state.export.focusMark.bodySize=1.4
        state.export.focusMark.captureFlash=True;state.export.focusMark.captureColor=FocusMarkColor.ORANGE
        state.export.aspect=AspectRatio(16,9,'16:9');state.export.shortSide=720;state.export.codec=VideoCodec.H264
        state.seek(0);state.set_manual_eye(state.analysis.track.head_center[0]+np.array([1.,1.]))
        state.add_closeup();shot=state.analysis.closeups[0];settle()
        for field,value in [('seconds',.3),('zoom',1.5)]:
            spin=window.findChild(QDoubleSpinBox,f'closeup-{id(shot)}-{field}');assert spin is not None
            spin.setValue(value)
        settle()
        key=state.analysis.fingerprint;count=len(state.job.output_frames)
        state._save_settings_now();saved=json.loads(state.settings_path.read_text(encoding='utf-8'))
        window.resize(1440,960);settle()
        assert window.grab().save(str(out/'aircraft-controls.png'))
        assert saved['subject']=='aircraft' and saved['composition']['anchorX']==.31
        assert saved['export']['focusMark']['headColor']=='orange'
        assert saved['profiles']['aircraft']['export']['focusMark']['headColor']=='white'
        VideoExporter().export_video(state.job,str(out/'aircraft-app.mp4'))
        state.cache.save_analysis(state.analysis.copy_edits());state.start_analysis()
        wait(lambda:state.phase=='ready' and state.job is not None);settle()
        assert state.analysis.fingerprint==key and state.analysis.manualEye and state.analysis.closeups
        state.close()
        restored=AppState()
        try:
            assert restored.subject=='aircraft' and restored.export.focusMark.headColor==FocusMarkColor.WHITE
            assert restored.export.focusMark.captureFlash and restored.export.focusMark.bodySize==1.4
            restored.change_subject('bird')
            assert restored.composition.anchorX==.31 and restored.export.focusMark.headColor==FocusMarkColor.ORANGE
        finally:restored.close()
        result=dict(subject='aircraft',photos=8,clips=2,heads=8,eye_frames=0,output_frames=count,
                    cancelled_switch_restored=True,separate_preferences=True,restart=True,cache_edits=True)
        (out/'subject-regression.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
        print(json.dumps(result),flush=True)
    finally:
        state.close();window.close();settle(.1)


if __name__=='__main__':
    import sys
    main(sys.argv[1:])
