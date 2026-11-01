"""Real import controls, lens correction and video exports in source and frozen builds."""
import json
import math
import os
from pathlib import Path
import time
from unittest.mock import patch

from PySide6.QtWidgets import QApplication, QComboBox

from . import theme
from .main_window import MainWindow
from .state import AppState
from .video_import import VideoImportDialog
from ..core.exporter import VideoExporter
from ..core.settings import AspectRatio, AudioTrack, EdgeFill, LockPoint, VideoCodec


def main(argv):
    if not os.environ.get('BIRDLOCK_DATA'):
        raise SystemExit('Video regression requires a disposable BIRDLOCK_DATA directory')
    if len(argv) != 3:
        raise SystemExit('Usage: --video-regression bird-video aircraft-video output')
    sources, out = argv[:2], Path(argv[2])
    out.mkdir(parents=True, exist_ok=True)
    app = QApplication([])
    theme.apply(app)
    state = AppState()
    state.device = 'cpu'
    window = MainWindow(state)
    window.show()

    def settle(seconds=.4):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            app.processEvents(); time.sleep(.005)

    def wait(condition, limit=240):
        end = time.monotonic() + limit
        while not condition():
            app.processEvents()
            if state.phase == 'failed': raise AssertionError(state.message)
            if time.monotonic() > end: raise TimeoutError(state.phase)
            time.sleep(.005)

    reports = []
    try:
        for subject, source in zip(('bird', 'aircraft'), sources):
            state.frames = []; state.segments = []; state.analysis = state.job = None; state.phase = 'empty'
            window.subject_combo.setCurrentIndex(window.subject_combo.findData(subject))
            settle()
            dialog = VideoImportDialog(source, state, window)
            dialog.show()
            wait(lambda: dialog.info is not None)
            info = dialog.info
            # Static zero-distortion calibration still exercises actual JSON loading and remapping.
            profile = out / (subject + '-lens.json')
            profile.write_text(json.dumps(dict(name='Regression calibration', distortion_model='opencv_standard',
                calib_dimension=dict(w=info.width, h=info.height), fisheye_params=dict(
                    camera_matrix=[[info.width,0,info.width/2],[0,info.width,info.height/2],[0,0,1]],
                    distortion_coeffs=[0,0,0,0,0]))), encoding='utf-8')
            with patch('birdlock.app.video_import.QFileDialog.getOpenFileName', return_value=(str(profile), '')):
                dialog.choose_profile()
            assert dialog.profile == str(profile)
            seconds, fps = min(.8, info.duration), min(30, info.fps)
            dialog.seconds.setValue(seconds); dialog.fps.setValue(fps)
            settle()
            assert dialog.grab().save(str(out / (subject + '-import.png')))
            dialog.go.click()
            wait(lambda: state.phase == 'ready' and state.job is not None)
            settle()
            expected = max(1, math.ceil(seconds * fps - 1e-6))
            assert state.analysis.count == expected and state.analysis.track.has_data.all()
            state.export.aspect = AspectRatio(16,9,'16:9'); state.export.shortSide = 720; state.export.codec = VideoCodec.H264
            state.composition.framing = 14 if subject == 'bird' else 8
            state.composition.edgeFill = EdgeFill.AUTO_ZOOM; state.composition.autoLeadRoom = False
            for point in ([LockPoint.EYE, LockPoint.HEAD_CENTER] if subject == 'bird' else [LockPoint.HEAD_CENTER]):
                if subject == 'bird':
                    combo = next(c for c in window.findChildren(QComboBox)
                        if c.findData(LockPoint.EYE) >= 0 and c.findData(LockPoint.HEAD_CENTER) >= 0)
                    combo.setCurrentIndex(combo.findData(point))
                else: state.composition.lockPoint = point
                state.settings_changed(); settle()
                assert state.composition.lockPoint == point
                VideoExporter().export_video(state.job, str(out / (subject + '-' + point.value + '.mp4')))
                reports.append(dict(subject=subject, lock=point.value, frames=state.analysis.count,
                                    tracked=int(state.analysis.track.has_data.sum()), lens_import=True))
            assert window.grab().save(str(out / (subject + '-preview.png')))
            state.current_frame = min(6, state.analysis.count-1)
            state.add_closeup(); state.analysis.closeups[0].seconds = .3
            state.audio.tracks = [AudioTrack(assetID='sony-20', volume=.3)]
            state.rebuild_job(immediate=True); settle()
            mixed = state.job.mixed_audio(state.audio)
            assert mixed.tracks[0].muteRanges and len(mixed.tracks) == 2
            VideoExporter().export_video(state.job, str(out / (subject + '-closeup.mp4')), state.audio)
            key = state.analysis.fingerprint
            state.cache.save_analysis(state.analysis.copy_edits())
            state.import_video(source, seconds=seconds, fps=fps, profile=str(profile))
            wait(lambda: state.phase == 'ready' and state.job is not None); settle()
            assert state.analysis.fingerprint == key and len(state.analysis.closeups) == 1
            previous = state.analysis
            state.import_video(str(out / 'missing.mp4'))
            wait(lambda: state.phase == 'ready')
            assert state.analysis is previous
            state.import_video(source, seconds=seconds, fps=fps, profile=str(profile))
            state.cancel_analysis(); settle()
            assert state.phase == 'ready' and state.analysis is previous
        (out / 'video-regression.json').write_text(json.dumps(dict(cases=reports, cache_edits=True,
            cancel_preserves_previous=True, failure_preserves_previous=True, closeup_mix=True), indent=2), encoding='utf-8')
        print(reports)
    finally:
        state.close(); window.close(); app.processEvents()
