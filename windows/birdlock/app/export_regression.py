"""Exercise cancellation through the real dialog, then export again without restarting."""
from pathlib import Path
import time

from .main_window import ExportDialog
from ..core.settings import VideoCodec, VideoQuality, AspectRatio
from PySide6.QtWidgets import QComboBox


def check_export_recovery(state,window,wait,settle,out):
    state.export.shortSide=720
    state.export.aspect=AspectRatio(16,9,'16:9')
    state.export.encoder='software'
    # Operate real widgets: QVariant can turn string enums into str; assigning
    # state.export.codec directly never reproduced that defect.
    def choose(enum_type, value):
        values = {v.value for v in enum_type}
        combo = next(c for c in window.findChildren(QComboBox)
                     if c.count() == len(values) and all(isinstance(c.itemData(i),str) for i in range(c.count()))
                     and {c.itemData(i) for i in range(c.count())} == values)
        combo.setCurrentIndex(combo.findData(value.value));settle(.15)
    codec_switches=[]
    for codec in (VideoCodec.HEVC, VideoCodec.H264, VideoCodec.PRORES_422HQ, VideoCodec.PRORES_4444):
        choose(VideoCodec,codec)
        choose(VideoQuality,VideoQuality.MAX if codec == VideoCodec.HEVC else VideoQuality.HIGH)
        assert isinstance(state.export.codec,VideoCodec) and isinstance(state.export.quality,VideoQuality)
        target=out/('widget-'+codec.value+'.'+codec.ext)
        state.export_to('video',str(target));wait(lambda:not state.export_running,limit=120)
        assert state.export_progress==1,state.export_message
        codec_switches.append(codec.value)
    results=[]
    for action in ('cancel-button','close-dialog'):
        state.export.codec=VideoCodec.H264
        state.export.repeatCount=8
        state.settings_changed();settle(.15)
        dialog=ExportDialog(state,window);dialog.show();settle(.05)
        cancelled=out/(action+'.mp4');cancelled.write_bytes(b'previous video must survive cancellation')
        state.export_to('video',str(cancelled))
        wait(lambda:state.export_progress>.015 or not state.export_running,limit=60)
        assert state.export_running,'Fixture completed before reaching cancellation'
        started=time.monotonic()
        if action=='cancel-button':dialog.cancel_btn.click()
        else:dialog.reject()
        wait(lambda:not state.export_running,limit=10)
        elapsed=time.monotonic()-started
        assert state.export_message=='已取消',state.export_message
        assert cancelled.read_bytes()==b'previous video must survive cancellation'
        assert state._export_thread is None
        dialog.accept()
        # A different codec in the same application and on the same photographs.
        choose(VideoCodec,VideoCodec.HEVC);state.export.repeatCount=1
        state.settings_changed();settle(.15)
        target=out/(action+'-retry-hevc.mp4')
        state.export_to('video',str(target));wait(lambda:not state.export_running,limit=120)
        assert state.export_progress==1,state.export_message
        assert target.stat().st_size>1000
        results.append(dict(action=action,cancel_seconds=elapsed,retry=state.export_message))
    # Replace the import with another sequence, still in the same process.
    paths=[f.path for f in state.analysis.frames[-6:]]
    state.import_paths(paths,merge=True)
    wait(lambda:state.phase=='ready' and state.analysis is not None and state.analysis.count==6,limit=120)
    state.export.encoder='software';state.export.codec=VideoCodec.H264;state.export.repeatCount=1
    state.settings_changed();settle(.15)
    target=out/'new-sequence-h264.mp4'
    state.export_to('video',str(target));wait(lambda:not state.export_running,limit=120)
    assert state.export_progress==1,state.export_message
    assert target.stat().st_size>1000
    state.export_to('gif',str(out/'after-cancel.gif'));wait(lambda:not state.export_running,limit=120)
    assert state.export_progress==1,state.export_message
    state.export_to('images',str(out/'after-cancel-images'));wait(lambda:not state.export_running,limit=120)
    assert state.export_progress==1,state.export_message
    assert len(list((out/'after-cancel-images').glob('*.jpg')))>0
    assert not list(out.glob('.BirdLock-export-*'))
    return dict(same_process=True,widget_codec_switches=codec_switches,cancellations=results,new_sequence_h264=True,gif=True,images=True,original_destination_preserved=True)
