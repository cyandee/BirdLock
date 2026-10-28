"""Own-app integration checks; edits in-memory metadata and an isolated cache, never the photos."""
import sys,time,json,wave,os
import numpy as np
from pathlib import Path
from unittest.mock import patch
from dataclasses import replace
from PySide6.QtWidgets import QApplication,QPushButton,QDoubleSpinBox,QCheckBox,QLabel,QDialog
from PySide6.QtCore import QTimer
from birdlock.app.state import AppState
from birdlock.app.main_window import MainWindow
from birdlock.app import theme
from birdlock.app.project_editor import ProjectEditor,MusicCueCard
from birdlock.core import frames as F
from birdlock.core.settings import FrameInterpolation,AspectRatio,VideoCodec,AudioTrack,AudioSettings
from birdlock.core.exporter import VideoExporter,render_audio_preview,_run_quiet,_ffmpeg
from birdlock.core.render import RenderJob


def check_short_audio(job,out):
    # Separate timing fixture: this export intentionally contains only its two synthetic tones.
    analysis=job.analysis.copy_edits()
    for shot in analysis.closeups:shot.shutterEnabled=False
    job=RenderJob(analysis,job.composition,job.look,job.export,job.selection,cache=job.cache)
    tracks=[]
    for name,rate,seconds,amplitude,offset,start in [('short-a.wav',48000,.2,.4,0,0),('short-b.wav',44100,.3,.2,.1,.4)]:
        path=out/name;t=np.arange(round(rate*seconds))/rate
        samples=(amplitude*np.sin(2*np.pi*440*t)*32767).astype('<i2')
        with wave.open(str(path),'wb') as wav:
            wav.setparams((2,2,rate,0,'NONE','not compressed'))
            wav.writeframes(np.repeat(samples[:,None],2,axis=1).tobytes())
        tracks.append(AudioTrack(path=str(path),loop=False,fadeIn=0,fadeOut=0,startOffset=offset,timelineStart=start))
    audio=AudioSettings(tracks=tracks)
    def levels(samples):
        return np.array([np.sqrt(np.mean(samples[round(a*48000):round(b*48000),0]**2))
                         for a,b in [(.04,.08),(.44,.48),(.25,.35),(.8,.9)]])
    for iteration in range(20):
        path=render_audio_preview(audio,job.duration)
        try:
            with wave.open(path,'rb') as wav:
                samples=np.frombuffer(wav.readframes(wav.getnframes()),'<i2').reshape(-1,2)/32768
            rms=levels(samples)
            np.testing.assert_allclose(rms[:2],[.2/np.sqrt(2),.1/np.sqrt(2)],rtol=.1,atol=.003,err_msg=f'PCM {iteration}')
            assert max(rms[2:])<.002
        finally:Path(path).unlink()
    video=out/'short-audio-eof.mp4'
    VideoExporter().export_video(job,str(video),audio=audio)
    decoded=_run_quiet([_ffmpeg(),'-v','error','-i',str(video),'-vn','-ac','2','-ar','48000','-f','f32le','-'],timeout=60)
    assert decoded.returncode==0,decoded.stderr[-500:]
    samples=np.frombuffer(decoded.stdout,'<f4').reshape(-1,2);rms=levels(samples)
    np.testing.assert_allclose(rms[:2],[.2/np.sqrt(2),.1/np.sqrt(2)],rtol=.15,atol=.008,err_msg='Exported AAC')
    assert max(rms[2:])<.012
    return dict(pcm_repetitions=20,exported_aac_rms=rms.tolist())


def main(argv=None):
    if not os.environ.get('BIRDLOCK_DATA'):
        raise SystemExit('Project regression requires a disposable BIRDLOCK_DATA directory')
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 2:
        raise SystemExit('Usage: --project-regression photos output')
    photos,out=args[0],Path(args[1]);out.mkdir(parents=True,exist_ok=True)
    app=QApplication([]);theme.apply(app);state=AppState();state.change_subject('bird');state.device='cpu';window=MainWindow(state);window.show()
    def wait(condition,limit=180):
     end=time.monotonic()+limit
     while not condition():
      app.processEvents()
      if state.phase=='failed':raise RuntimeError(state.message)
      if time.monotonic()>end:raise TimeoutError('Project operation timed out')
      time.sleep(.01)
    def settle(seconds=.4):
     end=time.monotonic()+seconds
     while time.monotonic()<end:app.processEvents();time.sleep(.01)
    raw=F.import_frames([photos])[:12]
    assert len(raw)==12
    frames=[replace(f,captureTime=(i/30 if i<6 else 10+(i-6)/30)) for i,f in enumerate(raw)]
    with patch('birdlock.core.frames.import_frames',return_value=frames):
     state.import_paths([photos],merge=True)
     wait(lambda:state.phase=='ready' and state.job is not None)
    assert state.segment_index==-1 and len(state.analysis.clips)==2
    state.export.interpolation=FrameInterpolation.BLEND;state.settings_changed();settle()
    assert not any(f.a<6<=f.b for f in state.job.output_frames)
    window.inspector.tabbar.setCurrentIndex(2);settle()
    state.seek(3)
    editor=window.findChild(ProjectEditor)
    button=next(b for b in editor.findChildren(QPushButton) if b.text()=='将当前照片设为特写')
    button.click();wait(lambda:bool(state.analysis.closeups));settle()
    shot=state.analysis.closeups[0]
    next(b for b in editor.findChildren(QPushButton) if b.text()=='将当前照片设为特写').click();settle()
    assert len(state.analysis.closeups)==1 and '已有特写' in state.timeline_message
    start=editor.findChild(QDoubleSpinBox,f"closeup-{id(shot)}-frame")
    start.setValue(5);settle(.12)
    assert shot.frame==shot.endFrame==4
    start.setValue(4);settle(.12)
    for key,value in [('endFrame',5),('seconds',.8),('zoom',1.8),('centerX',.4),('centerY',.6)]:
        control=editor.findChild(QDoubleSpinBox,f"closeup-{id(shot)}-{key}")
        assert control is not None and control.accessibleName()
        # Exercise an actual value change even when the rounded default already reads the target.
        control.stepUp();control.setValue(value);settle(.12)
    wait(lambda:len(state.job.output_frames)==34);settle()
    actual=(shot.endFrame,shot.seconds,shot.zoom,shot.centerX,shot.centerY)
    assert np.allclose(actual,(4,.8,1.8,.4,.6)),actual
    state.seek(8)
    next(b for b in editor.findChildren(QPushButton) if b.text()=='将当前照片设为特写').click()
    settle()
    extra=next(s for s in state.analysis.closeups if s is not shot)
    editor.findChild(QDoubleSpinBox,f"closeup-{id(shot)}-frame").setValue(9);settle(.12)
    assert (shot.frame,shot.endFrame)==(3,4) and '不能重叠' in state.timeline_message
    editor.findChild(QPushButton,f"remove-closeup-{id(extra)}").click();settle()
    wait(lambda:len(state.job.output_frames)==34)
    assert not state.timeline_message
    state.seek(4);settle()
    assert state.job.preview_frame(4).a==3 and state.job.preview_frame(4).closeup==0
    state.cache.save_analysis(state.analysis)
    restored=state.cache.load_analysis(state.analysis.fingerprint)
    assert len(restored.clips)==2 and restored.closeups[0].zoom==1.8
    # Simulate reopening an older multi-group cache: raw detections are rebuilt, edits survive.
    restored.groupedDetection=False
    state.cache.save_analysis(restored)
    state.analysis=None
    state.start_analysis()
    wait(lambda:state.phase=='ready' and state.analysis.groupedDetection and len(state.job.output_frames)==34)
    assert len(state.analysis.closeups)==1 and state.analysis.closeups[0].zoom==1.8
    # Exercise the real audio overview and alignment controls with a disposable synthetic music fixture.
    rate=22050;t=np.arange(rate*8)/rate;amp=np.full(len(t),.035)
    amp[(t>=5.5)&(t<7.5)]=.5
    for beat in (1,2,3):amp[(t>=beat)&(t<beat+.08)]=.8
    music=out/'music-cue-fixture.wav'
    with wave.open(str(music),'wb') as wav:
     wav.setnchannels(1);wav.setsampwidth(2);wav.setframerate(rate)
     wav.writeframes((amp*np.sin(2*np.pi*330*t)*32767).astype('<i2').tobytes())
    state.set_audio(str(music));wait(lambda:bool(state.music_cues));settle()
    cue_card=window.findChild(MusicCueCard);state.seek(4);settle()
    cue=cue_card.cues.currentData();assert cue is not None and cue>.1
    cue_card.align();settle();assert abs(state.audio.startOffset-(cue-.1))<1e-6
    offset=state.audio.startOffset
    state.selection.trimStart=6;state.settings_changed();wait(lambda:4 not in state.job.used);settle()
    cue_card.align();assert state.audio.startOffset==offset and '未出现在成片' in cue_card.message.text()
    state.selection.trimStart=0;state.settings_changed();wait(lambda:len(state.job.output_frames)==34);settle()
    state.remove_audio();settle()
    window.inspector.tabbar.setCurrentIndex(2);settle()
    for width in (1100,1360):
     window.resize(width,860);settle()
     tab=window.inspector.tabs[2];assert tab.widget().width()==tab.viewport().width() and tab.horizontalScrollBar().maximum()==0
     tab.verticalScrollBar().setValue(editor.y());settle();window.grab().save(str(out/f'project-editor-{width}.png'))
    settings=state.export.copy();settings.shortSide=720;settings.aspect=AspectRatio(16,9,'16:9');settings.codec=VideoCodec.H264
    job=RenderJob(state.analysis.copy_edits(),state.composition.copy(),state.look.copy(),settings,state.selection.copy(),cache=state.cache)
    VideoExporter().export_video(job,str(out/'group-closeup.mp4'))
    decoded=_run_quiet([_ffmpeg(),'-v','error','-i',str(out/'group-closeup.mp4'),'-vn','-ac','2','-ar','48000','-f','f32le','-'],timeout=60)
    assert decoded.returncode==0,decoded.stderr[-500:]
    single_samples=np.frombuffer(decoded.stdout,'<f4').reshape(-1,2)
    single_events=job.mixed_audio().arranged_tracks
    assert len(single_events)==1 and not single_events[0].loop
    assert np.max(np.abs(single_samples[round(.11*48000):round(.4*48000)]))>.01
    assert np.max(np.abs(single_samples[round(.6*48000):]))<.012
    # Exercise actual group order buttons; edit/cache identity must follow the source photo.
    old_photo=state.analysis.frames[3].path
    state.analysis.manualEye[0]=tuple(state.analysis.track.head_center[0]);state.analysis.excluded.add(1)
    first=state.analysis.frames[0].path
    down=next(b for b in editor.findChildren(QPushButton) if b.text()=='下移' and b.isEnabled())
    down.click();wait(lambda:state.merge_group_indices==[1,0] and state.job.analysis.fingerprint==state.analysis.fingerprint);settle()
    assert state.analysis.frames[6].path==first and state.analysis.frames[state.analysis.closeups[0].frame].path==old_photo
    assert state.analysis.closeups[0].frame==9 and state.analysis.closeups[0].endFrame==10
    assert 6 in state.analysis.manualEye and 7 in state.analysis.excluded
    assert state.cache.load_analysis(state.analysis.fingerprint).closeups[0].frame==9
    up=next(b for b in editor.findChildren(QPushButton) if b.text()=='上移' and b.isEnabled())
    up.click();wait(lambda:state.merge_group_indices==[0,1] and state.job.analysis.fingerprint==state.analysis.fingerprint);settle()
    assert state.analysis.closeups[0].frame==3 and state.analysis.frames[0].path==first
    state.analysis.excluded.remove(1);state.project_changed();settle()
    # Camera first, recording second, on the real multi-track card.
    from .audio_tracks import AudioTracksCard,CameraSoundPicker
    from ..core.sounds import assets
    card=window.findChild(AudioTracksCard);picker=card.sounds
    assert picker.camera.count()==5
    for camera,expected in [('sony-a1m2',5),('sony-a93',2),('sony-a7m5',2),('nikon-z8',1),('sony-a7r6',1)]:
        picker.camera.setCurrentIndex(picker.camera.findData(camera));settle(.05)
        assert picker.recording.count()==expected
    picker.camera.setCurrentIndex(picker.camera.findData('nikon-z8'));card.add_shutter();settle()
    assert state.audio.tracks[-1].assetID=='nikon-z8'
    track_picker=[p for p in card.findChildren(CameraSoundPicker) if p is not picker][-1]
    track_picker.camera.setCurrentIndex(track_picker.camera.findData('sony-a7m5'));settle()
    assert state.audio.tracks[-1].assetID=='sony-a7m5-30'
    track_picker.recording.setCurrentIndex(track_picker.recording.findData('sony-a7m5-15'));settle()
    assert state.audio.tracks[-1].assetID=='sony-a7m5-15'
    state.audio.tracks=[];state.audio_settings_changed();settle()
    # Open the visible, voluntary toolbar entry and verify its image.
    def inspect_support():
        dialog=QApplication.activeModalWidget()
        assert isinstance(dialog,QDialog)
        labels=dialog.findChildren(QLabel)
        assert any(l.pixmap() is not None and not l.pixmap().isNull() for l in labels)
        assert any('全部功能' in l.text() or '所有功能' in l.text() for l in labels)
        dialog.grab().save(str(out/'coffee-support.png'));dialog.accept()
    assert window.support_btn.isVisible()
    QTimer.singleShot(150,inspect_support);window.support_btn.click();settle()
    assert any('赞赏' in action.text() for action in window.menuBar().actions())
    logs=out/'diagnostics.zip'
    with patch('birdlock.app.main_window.QFileDialog.getSaveFileName',return_value=(str(logs),'ZIP')),patch('birdlock.app.main_window.QMessageBox.information'):
        window.export_diagnostics()
    import zipfile
    with zipfile.ZipFile(logs) as z:
        assert 'system.json' in z.namelist() and 'birdlock.log' in z.namelist()
        assert not any(n.endswith(('.jpg','.onnx','settings.json')) for n in z.namelist())
    from .. import CONTACT_EMAIL
    assert CONTACT_EMAIL=='cyanodee@gmail.com'
    audio_eof=check_short_audio(job,out)
    state.select_segment(0);wait(lambda:state.phase=='ready' and state.analysis.count==6 and state.job.analysis.count==6)
    assert len(state.analysis.closeups)==0
    state.select_segment(-1);wait(lambda:state.phase=='ready' and state.analysis.count==12 and len(state.analysis.closeups)==1 and len(state.job.output_frames)==34)
    state.toggle_play();settle(.6);state.stop();settle()
    from .export_regression import check_export_recovery
    export_recovery=check_export_recovery(state,window,wait,settle,out)
    result=dict(group_order_buttons_preserve_edits=True,camera_variant_menus=True,single_shutter_aac=True,coffee_dialog_image=True,contact_email=True,photos=12,clips=2,closeups=1,frames=34,duration=job.duration,restore_after_group_switch=True,legacy_group_cache_preserves_edits=True,music_alignment_resolves_closeup_and_rejects_trimmed=True,layout_checks=2,short_audio_eof=audio_eof,export_recovery=export_recovery)
    result['diagnostic_bundle']=True;result['visible_support_entry']=True
    (out/'project-regression.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result),flush=True)
    window.close();app.processEvents()
