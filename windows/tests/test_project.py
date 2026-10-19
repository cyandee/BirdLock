import unittest
from types import SimpleNamespace
import numpy as np
from birdlock.core.settings import ExportSettings,FrameInterpolation,Closeup,LoopMode
from birdlock.core.render import project_frames,RenderJob,OutputFrame
from birdlock.core.music_cues import analyze


class ProjectTests(unittest.TestCase):
    def test_target_identity_resets_at_cuts_and_hint_is_local_to_its_clip(self):
        from birdlock.core.analysis import Box, track_targets
        left=Box(0,0,100,100,.99);distractor=Box(0,0,100,100,.2);right=Box(1000,0,100,100,.9)
        detections=[[left],[left],[distractor,right],[distractor,right]]
        clips=[dict(start=0,count=2,fps=30),dict(start=2,count=2,fps=30)]
        self.assertEqual(track_targets(detections),[0,0,0,0])
        self.assertEqual(track_targets(detections,clips=clips),[0,0,1,1])
        self.assertEqual(track_targets(detections,hint=(2,(50,50)),clips=clips),[0,0,0,0])

    def test_imported_groups_keep_different_capture_rates(self):
        from birdlock.core.frames import segments
        frames=[SimpleNamespace(captureTime=i/10) for i in range(6)]+[SimpleNamespace(captureTime=4+i/20) for i in range(6)]
        groups=segments(frames)
        self.assertEqual([g.fps for g in groups],[10,20])

    def test_individual_clip_rates_and_no_interpolation_across_cuts(self):
        settings=ExportSettings(outputFPS=30,interpolation=FrameInterpolation.BLEND)
        clips=[dict(start=0,count=5,fps=10),dict(start=5,count=5,fps=30)]
        frames=project_frames(list(range(10)),clips,[],30,settings)
        self.assertEqual(len(frames),18)
        self.assertTrue(all((f.a<5)==(f.b<5) for f in frames))
        self.assertEqual(frames[-1].time,17/30)

    def test_closeup_replaces_range_and_extends_duration(self):
        shot=Closeup(frame=1,endFrame=2,seconds=2)
        frames=project_frames([0,1,2,3],[],[shot],30,ExportSettings())
        self.assertEqual(len(frames),62)
        self.assertEqual(sum(f.closeup==0 for f in frames),60)
        self.assertEqual([f.a for f in frames if f.closeup<0],[0,3])
        self.assertTrue(all(f.a==f.b==1 for f in frames if f.closeup==0))
        self.assertAlmostEqual(frames[60].shotTime,59/30)

    def test_excluded_anchor_does_not_reappear_as_closeup(self):
        frames=project_frames([0,2,3],[],[Closeup(frame=1,endFrame=2)],30,ExportSettings())
        self.assertNotIn(1,[f.a for f in frames])
        self.assertTrue(all(f.closeup==-1 for f in frames))

    def test_music_alignment_resolves_replaced_photo_and_rejects_omitted_photo(self):
        from birdlock.core.render import project_source_time
        shot=Closeup(frame=1,endFrame=2,seconds=2)
        frames=project_frames([0,1,2,3],[],[shot],30,ExportSettings())
        self.assertAlmostEqual(project_source_time(2,frames,[shot]),1/30)
        self.assertAlmostEqual(project_source_time(3,frames,[shot]),61/30)
        self.assertIsNone(project_source_time(9,frames,[shot]))
        trimmed=project_frames([0,3],[],[shot],30,ExportSettings())
        self.assertIsNone(project_source_time(2,trimmed,[shot]))

    def test_reverse_and_repeat_preserve_monotonic_output_clock(self):
        settings=ExportSettings(loop=LoopMode.REVERSE,repeatCount=2)
        frames=project_frames([0,1,2],[],[],30,settings)
        self.assertEqual([f.a for f in frames],[2,1,0,2,1,0])
        self.assertEqual([f.time for f in frames],[k/30 for k in range(6)])

    def test_music_cues_and_silence(self):
        self.assertEqual(analyze(np.zeros(480)),[])
        self.assertEqual(analyze(np.ones(480)*0.2),[])
        peaks=np.full(480,0.1);peaks[80]=0.9;peaks[160]=0.9;peaks[320:440]=0.7
        cues=analyze(peaks)
        self.assertTrue(any(abs(c['time']-2)<0.1 and not c['climax'] for c in cues))
        self.assertTrue(any(8<=c['time']<=11 and c['climax'] for c in cues))

    def test_closeup_zoom_pan_changes_pixels_without_changing_global_composition(self):
        job=RenderJob.__new__(RenderJob);job.export=ExportSettings()
        job.contains=lambda _:True
        image=np.zeros((200,200,3),np.uint8);image[76:85,76:85]=(0,0,255)
        job.compose=lambda *args:image.copy();job._text_overlay=lambda *args:None;job.watermark_image=lambda:None
        shot=Closeup(frame=0,endFrame=0,zoom=2,centerX=0.4,centerY=0.4,animatedFrame=False)
        job.analysis=SimpleNamespace(closeups=[shot])
        result=job.render_output(OutputFrame(0,0,0,1,closeup=0),fetch=lambda _:(None,1))
        self.assertEqual(result[100,100,2],255)
        self.assertEqual(result[40,40,2],0)
