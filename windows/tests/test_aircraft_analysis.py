"""Subject isolation, explicit missing noses and the photo-to-render aircraft backend."""
import hashlib
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import cv2
import numpy as np

from birdlock.core.aircraft import NoseObservation
from birdlock.core.aircraft_sequence import AircraftFrameObservation
from birdlock.core.aircraft_analysis import AircraftAnalyzer, analysis_identity
from birdlock.core.analysis import Box, Cancelled, FrameAnalysis, ProxyCache, SequenceAnalysis, build_track, fingerprint
from birdlock.core.frames import SourceFrame, write_jpeg
from birdlock.core.models import CUB15, Detection
from birdlock.core.render import RenderJob, OutputFrame
from birdlock.core.settings import Composition, EdgeFill, ExportSettings, FrameSelection, LookSettings, FocusMarkColor


class AircraftAnalysisTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.manifest_dir = Path(__file__).resolve().parents[2]/'SharedResources/AircraftModels'

    def analysis(self, count=3):
        frames = [SourceFrame(i,str(self.root/f'{i}.png'),640,480,fileSize=1,modified=1) for i in range(count)]
        per = []
        for i in range(count):
            frame = FrameAnalysis(i,birds=[Box(50,50,200,100,.9)],target=0)
            if i != 1:
                frame.aircraft = AircraftFrameObservation(NoseObservation(60+i*2,70,20,14,.6,3),'detected')
            per.append(frame)
        return SequenceAnalysis('test',frames,30,640,per,CUB15,subject='aircraft',modelIdentity='parts-v1')

    def test_legacy_cache_edits_survive_and_subject_model_keys_cannot_collide(self):
        a = self.analysis()
        a.manualEye[1] = (74,77);a.excluded.add(2)
        a.groupedDetection = True
        saved = a.to_dict()
        old = json.loads(json.dumps(saved));old.pop('subject');old.pop('modelIdentity')
        for frame in old['perFrame']:frame.pop('aircraft')
        restored = SequenceAnalysis.from_dict(old)
        self.assertEqual(restored.subject,'bird')
        self.assertEqual(restored.manualEye,{1:(74,77)})
        self.assertEqual(restored.excluded,{2})
        self.assertTrue(restored.groupedDetection)
        modern = SequenceAnalysis.from_dict(json.loads(json.dumps(saved)))
        self.assertEqual(modern.subject,'aircraft');self.assertEqual(modern.modelIdentity,'parts-v1')
        np.testing.assert_allclose(modern.perFrame[0].aircraft.nose.center,[70,77])
        copy = modern.copy_edits();copy.manualEye[1] = (80,81);copy.excluded.clear()
        self.assertEqual(modern.manualEye[1],(74,77));self.assertEqual(modern.excluded,{2})
        self.assertEqual((copy.subject,copy.modelIdentity),('aircraft','parts-v1'))
        expected = hashlib.sha256(''.join(f'{f.path}|{f.fileSize}|{f.modified}\n' for f in a.frames).encode()).hexdigest()[:24]
        self.assertEqual(fingerprint(a.frames),expected)
        keys = [expected,fingerprint(a.frames,'aircraft','v1'),fingerprint(a.frames,'aircraft','v2')]
        self.assertEqual(len(set(keys)),3)
        with self.assertRaises(ValueError):fingerprint(a.frames,'aircraft')

    def test_aircraft_ignores_bird_pose_and_body_centres_for_missing_noses(self):
        a = self.analysis()
        for frame in a.perFrame:
            frame.head.points[3] = (500,400);frame.head.conf[3] = 1
            frame.link = dict(delta=[200,150],quality=100,patchScale=1)
        track = build_track(a)
        self.assertEqual(track.has_data.tolist(),[True,False,True])
        self.assertEqual(track.eye_visible.tolist(),[False]*3)
        self.assertEqual(track.measured_eye,[None]*3)
        np.testing.assert_allclose(track.head_center[[0,2]],[[70,77],[74,77]],atol=1e-6)
        self.assertIsNone(a.perFrame[1].aircraft)
        for frame in a.perFrame:frame.aircraft = None
        self.assertFalse(build_track(a).has_data.any())
        a.manualEye[1] = (80,90)
        manual = build_track(a)
        self.assertEqual(manual.has_data.tolist(),[False,True,False])
        np.testing.assert_allclose(manual.head_center[1],[80,90])
        self.assertFalse(manual.eye_visible.any())

    def test_aircraft_render_has_head_and_body_but_never_an_eye_frame(self):
        a = self.analysis();a.track = build_track(a)
        export = ExportSettings(shortSide=720)
        fm = export.focusMark
        fm.enabled = fm.showHead = fm.showBody = fm.showEye = True
        fm.headColor,fm.bodyColor = FocusMarkColor.ORANGE,FocusMarkColor.GREEN
        job = RenderJob(a,Composition(edgeFill=EdgeFill.BLACK,autoLeadRoom=False),LookSettings(),export,
                        FrameSelection(dropUntracked=False,dropBlurry=False),cache=ProxyCache(self.root/'cache'))
        self.assertIsNone(job.focus_rect(0,'eye',1))
        self.assertIsNotNone(job.focus_rect(0,'head',1))
        self.assertIsNone(job.focus_rect(1,'head',1))
        self.assertIsNotNone(job.focus_rect(1,'body',1))
        image = np.full((480,640,3),127,np.uint8)
        with patch('birdlock.core.render.draw_focus_mark') as draw:
            job.render_output(OutputFrame(0,0,0,1),fetch=lambda _: (image,1))
        self.assertEqual([call.args[5] for call in draw.call_args_list],[fm.headColor.bgr,fm.bodyColor.bgr])

    def test_nose_measurements_do_not_leak_into_a_missing_head_burst(self):
        a = self.analysis(4)
        a.clips = [dict(start=0,count=2,fps=30),dict(start=2,count=2,fps=30)]
        a.perFrame[0].aircraft = a.perFrame[1].aircraft = None
        for i in (2,3):
            a.perFrame[i].aircraft = AircraftFrameObservation(NoseObservation(400+i,150,40,30,.6,3),'detected')
        track = build_track(a)
        self.assertEqual(track.has_data.tolist(),[False,False,True,True])
        np.testing.assert_array_equal(track.head_center[:2],np.zeros((2,2)))
        np.testing.assert_allclose(track.head_center[2:],[ [422,165],[423,165] ])
        self.assertEqual(track.head_length[:2].tolist(),[100,100])

    def test_displayed_airframe_includes_independently_detected_nose_without_changing_raw_box(self):
        a = self.analysis()
        a.perFrame[0].birds[0] = Box(100,50,150,100,.9)
        a.track = build_track(a)
        job = RenderJob(a,Composition(edgeFill=EdgeFill.BLACK,autoLeadRoom=False),LookSettings(),ExportSettings(shortSide=720),
                        FrameSelection(dropUntracked=False,dropBlurry=False),cache=ProxyCache(self.root/'cache'))
        rectangle = job.focus_rect(0,'body',1)
        nose = a.perFrame[0].aircraft.nose
        mapped = job.plan.xforms[0].map([nose.x,nose.y])
        self.assertTrue(np.all(mapped >= rectangle[:2]-rectangle[2:]/2))
        self.assertTrue(np.all(mapped <= rectangle[:2]+rectangle[2:]/2))
        self.assertEqual(a.perFrame[0].target_box.x,100)
        self.assertEqual(a.perFrame[0].target_box.w,150)

    def fixture(self):
        folder = self.root/'飞机照片';folder.mkdir()
        rng = np.random.default_rng(20261018)
        image = cv2.GaussianBlur(rng.integers(0,256,(480,640,3),dtype=np.uint8),(3,3),.7)
        frames = []
        for i in range(3):
            path = folder/f'{i}.jpg';write_jpeg(image,str(path),95)
            frames.append(SourceFrame(i,str(path),640,480,fileSize=path.stat().st_size,modified=path.stat().st_mtime))
        class BodyDetector:
            airplane_class = 4
            def detect(self, image, class_index=None, **kwargs):
                if class_index != 4:raise AssertionError('Wrong subject class')
                return [Detection(60,50,160,120,.9)]
        class Parts:
            calls = 0
            closes = 0
            def detect(self, image, body, **kwargs):
                self.calls += 1
                return NoseObservation(110,100,20,14,.6,3)
            def close(self):self.closes += 1
        class ForbiddenPose:
            def detect(self,*args,**kwargs):raise AssertionError('Bird pose was called for aircraft')
        return frames,SimpleNamespace(detector=BodyDetector(),pose=ForbiddenPose()),Parts()

    def test_photo_backend_scales_noses_and_preserves_originals_and_bird_cache(self):
        frames,models,parts = self.fixture()
        before = [hashlib.sha256(Path(f.path).read_bytes()).hexdigest() for f in frames]
        cache = ProxyCache(self.root/'cache')
        sentinel = cache.directory(fingerprint(frames))/'analysis.json';sentinel.write_text('bird cache')
        analyzer = AircraftAnalyzer(models,cache,self.manifest_dir,parts,proxy_long_side=320)
        a = analyzer.analyze(frames,30)
        self.assertEqual((a.subject,a.modelIdentity),('aircraft',analysis_identity(self.manifest_dir)))
        self.assertEqual(a.fingerprint,fingerprint(frames,'aircraft',a.modelIdentity))
        self.assertEqual(parts.calls,1);self.assertEqual(parts.closes,1)
        self.assertEqual(a.poseSchema.keypoints,[])
        self.assertTrue(all(not p.keypoints and p.head.valid_count == 0 for p in a.perFrame))
        self.assertTrue(a.track.has_data.all())
        np.testing.assert_allclose(a.perFrame[0].aircraft.nose.center,[240,214])
        self.assertEqual(a.perFrame[0].aircraft.nose.w,40)
        self.assertEqual(sentinel.read_text(),'bird cache')
        self.assertEqual([hashlib.sha256(Path(f.path).read_bytes()).hexdigest() for f in frames],before)
        cache.save_analysis(a)
        restored = cache.load_analysis(a.fingerprint)
        self.assertEqual(restored.subject,'aircraft')
        self.assertEqual(restored.modelIdentity,a.modelIdentity)

    def test_cancel_and_missing_aircraft_class_close_parts_without_pose_fallback(self):
        frames,models,parts = self.fixture()
        analyzer = AircraftAnalyzer(models,ProxyCache(self.root/'cache'),self.manifest_dir,parts,proxy_long_side=320)
        with self.assertRaises(Cancelled):analyzer.analyze(frames,30,cancelled=lambda:True)
        self.assertEqual((parts.calls,parts.closes),(0,1))
        models.detector.airplane_class = None
        with self.assertRaisesRegex(ValueError,'飞机类别'):analyzer.analyze(frames,30)
        self.assertEqual((parts.calls,parts.closes),(0,2))

    def test_owned_body_detector_is_released_before_large_parts_stage(self):
        import weakref
        frames,models,parts = self.fixture()
        body_type = type(models.detector)
        models = None
        refs = []
        def factory():
            detector = body_type();refs.append(weakref.ref(detector))
            return SimpleNamespace(detector=detector)
        original = parts.detect
        def check_released(*args,**kwargs):
            self.assertIsNone(refs[0]())
            return original(*args,**kwargs)
        parts.detect = check_released
        analyzer = AircraftAnalyzer(cache=ProxyCache(self.root/'scoped-cache'),parts_directory=self.manifest_dir,
                                    parts_model=parts,models_factory=factory,proxy_long_side=320)
        result = analyzer.analyze(frames,30)
        self.assertTrue(result.track.has_data.all());self.assertEqual(parts.closes,1)


if __name__ == '__main__':
    unittest.main()
