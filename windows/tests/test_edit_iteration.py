import tempfile, unittest, wave, os
from pathlib import Path
import numpy as np
from birdlock.core.analysis import SequenceAnalysis, FrameAnalysis, fingerprint, ProxyCache
from birdlock.core.frames import SourceFrame
from birdlock.core.models import CUB15
from birdlock.core.clip_order import reorder
from birdlock.core.closeup_audio import tracks, gain
from birdlock.core.render import project_frames, RenderJob
from birdlock.core.settings import Closeup, ExportSettings, AudioSettings, AudioTrack, LoopMode, Composition, LookSettings, FrameSelection
from birdlock.core.exporter import render_audio_preview


class EditIterationTests(unittest.TestCase):
    def fixture(self):
        frames=[SourceFrame(i,f'/photo-{i}.jpg',640,480,captureTime=i/30) for i in range(6)]
        a=SequenceAnalysis(fingerprint(frames),frames,30,640,[FrameAnalysis(i,sharpness=float(i)) for i in range(6)],CUB15)
        a.clips=[dict(start=0,count=2,fps=10),dict(start=2,count=2,fps=30),dict(start=4,count=2,fps=15)]
        a.groupedDetection=True;a.manualEye={0:(40,50),3:(60,70)};a.excluded={1,4}
        a.closeups=[Closeup(frame=2,endFrame=3,seconds=.5)]
        return a

    def test_reorder_keeps_photo_edits_and_independent_capture_rates(self):
        a=self.fixture();original=a.to_dict()
        b,mapping=reorder(a,[2,0,1])
        self.assertEqual(mapping,[4,5,0,1,2,3]);self.assertEqual([f.id for f in b.frames],list(range(6)))
        self.assertEqual([p.sharpness for p in b.perFrame],[4,5,0,1,2,3]);self.assertEqual(b.manualEye,{2:(40,50),5:(60,70)})
        self.assertEqual(b.excluded,{0,3});self.assertEqual((b.closeups[0].frame,b.closeups[0].endFrame),(4,5))
        self.assertEqual([c['fps'] for c in b.clips],[15,10,30]);self.assertEqual(a.to_dict(),original)
        c,_=reorder(b,[1,2,0]);self.assertEqual(c.to_dict(),original)
        b.subject='aircraft';b.modelIdentity='fixture';c,_=reorder(b,[1,2,0]);self.assertNotEqual(c.fingerprint,a.fingerprint)

    def test_cross_cut_closeup_and_invalid_permutation_leave_original_unchanged(self):
        a=self.fixture();a.closeups=[Closeup(frame=1,endFrame=2)]
        before=a.to_dict()
        with self.assertRaisesRegex(ValueError,'特写跨越'):reorder(a,[2,0,1])
        with self.assertRaises(ValueError):reorder(a,[0,0,2])
        self.assertEqual(a.to_dict(),before)

    def test_old_closeup_silent_new_closeup_enabled_roundtrip(self):
        self.assertFalse(Closeup.from_dict({'frame':2}).shutterEnabled)
        shot=Closeup(frame=2);self.assertTrue(shot.shutterEnabled)
        self.assertTrue(Closeup.from_dict(shot.to_dict()).shutterEnabled)

    def test_shutter_is_one_shot_and_follows_reverse_repeat_trim_exclusion(self):
        shot=Closeup(frame=1,endFrame=2,seconds=1)
        s=ExportSettings(repeatCount=2)
        forward=project_frames([0,1,2,3],[],[shot],30,s)
        events=tracks(forward,[shot]);self.assertEqual(len(events),2)
        self.assertEqual([t.timelineStart for t in events],[1/30,33/30]);self.assertTrue(all(not t.loop and t.fadeIn==0 and t.fadeOut==0 for t in events))
        s.loop=LoopMode.REVERSE
        self.assertEqual([t.timelineStart for t in tracks(project_frames([0,1,2,3],[],[shot],30,s),[shot])],[1/30,33/30])
        self.assertEqual(tracks(project_frames([0,2,3],[],[shot],30,s),[shot]),[])
        self.assertEqual(tracks(project_frames([3],[],[shot],30,s),[shot]),[])
        single=Closeup(seconds=1/30);s.loop=LoopMode.FORWARD
        self.assertEqual(len(tracks(project_frames([0],[],[single],30,s),[single])),2)
        s.loop=LoopMode.PING_PONG;s.repeatCount=1
        self.assertEqual(len(tracks(project_frames([0],[],[single],30,s),[single])),1)

    def test_headroom_uses_concurrent_events_and_muting(self):
        background=AudioTrack(assetID='nikon-z8',volume=.5)
        shots=[AudioTrack(assetID='single-canon-rebel',timelineStart=i,duration=.2,volume=.7) for i in range(1,10)]
        self.assertAlmostEqual(gain([background,*shots],10),1/1.2)
        self.assertAlmostEqual(gain([*shots,shots[0]],10),1/1.4)
        for t in shots:t.muted=True
        self.assertEqual(gain([background,*shots],10),1)

    def test_actual_single_shot_preview_has_silence_before_and_after(self):
        shot=Closeup(frame=1,seconds=1)
        frames=project_frames([0,1,2],[],[shot],10,ExportSettings(outputFPS=10))
        result=render_audio_preview(AudioSettings(tracks=tracks(frames,[shot])),len(frames)/10)
        self.addCleanup(lambda:os.path.exists(result) and os.unlink(result))
        with wave.open(result,'rb') as w:
            samples=np.frombuffer(w.readframes(w.getnframes()),'<i2').reshape(-1,2)/32768
        self.assertEqual(len(samples),57600)
        self.assertLess(np.max(np.abs(samples[:4700])),.001)
        self.assertGreater(np.max(np.abs(samples[4800:17000])),.01)
        self.assertLess(np.max(np.abs(samples[24000:])),.001)
