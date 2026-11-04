import json
from pathlib import Path
import tempfile
import unittest
import cv2
import numpy as np
from birdlock.core.analysis import SequenceAnalysis,FrameAnalysis,Box,ProxyCache,build_track,fingerprint,Cancelled
from birdlock.core.models import CUB15,PoseSchema
from birdlock.core.frames import SourceFrame,write_jpeg
from birdlock.core.custom_tracking import prepare,retrack,valid_seed,build_custom_track
from birdlock.core.clip_order import reorder
from birdlock.core.workspace import native_analysis,local_analysis


class TrackingTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)

    def birds(self,n=30):
        frames=[SourceFrame(i,str(self.root/f'{i}.jpg'),600,400,fileSize=1,modified=1) for i in range(n)];per=[]
        for i in range(n):
            k=[(0,0,0.) for _ in CUB15.keypoints]
            for name,xy in [('beak',(150+i,115)),('crown',(112+i,75)),('nape',(90+i,100)),('throat',(110+i,130)),('left_eye',(110+i,100)),('right_eye',(130+i,100))]:
                cf=.99 if (name=='left_eye' and i<15) or (name=='right_eye' and i>=15) else .65
                k[CUB15.index(name)]=(*xy,cf)
            per.append(FrameAnalysis(i,birds=[Box(70+i,60,130,100,.9)],target=0,keypoints=k))
        return SequenceAnalysis('birds',frames,30,600,per,CUB15)

    def test_fixed_eye_uses_same_identity_and_manual_edits_remain_stronger(self):
        a=self.birds();a.eyeSelections=[dict(frame=29,side='left_eye')]
        track=build_track(a)
        for i in range(a.count):np.testing.assert_allclose(track.measured_eye[i],(110+i,100))
        a.manualEye[20]=(128,102);np.testing.assert_allclose(build_track(a).eye[20],(128,102),atol=.3)
        restored=SequenceAnalysis.from_dict(json.loads(json.dumps(a.to_dict())))
        self.assertEqual(restored.eyeSelections,a.eyeSelections)
        restored.eyeSelections=[]
        self.assertGreater(build_track(restored).measured_eye[-1][0],track.measured_eye[-1][0]+10)

    def test_eye_choices_and_custom_references_follow_clip_reordering(self):
        a=self.birds(8);a.clips=[dict(start=0,count=4,fps=30),dict(start=4,count=4,fps=30)];a.groupedDetection=True
        a.eyeSelections=[dict(frame=3,side='left_eye'),dict(frame=7,side='right_eye')]
        moved,_=reorder(a,[1,0])
        self.assertEqual(moved.selected_eye(0),'right_eye');self.assertEqual(moved.selected_eye(7),'left_eye')
        self.assertAlmostEqual(build_track(moved).measured_eye[0][0],134)
        self.assertAlmostEqual(build_track(moved).measured_eye[7][0],113)

    def sequence(self,count=9,blank=()):
        rng=np.random.default_rng(3);texture=rng.integers(20,235,(70,90,3),np.uint8);frames=[]
        for i in range(count):
            image=np.full((360,480,3),90,np.uint8)
            if i not in blank:image[80+4*i:150+4*i,110+7*i:200+7*i]=texture
            path=self.root/f'photo-{i}.png';cv2.imwrite(str(path),image)
            frames.append(SourceFrame(i,str(path),480,360,fileSize=path.stat().st_size,modified=1))
        cache=ProxyCache(self.root/'cache');a=prepare(frames,30,cache)
        a.customSeeds=[dict(frame=4,box=dict(x=138.,y=96.,w=90.,h=70.,score=1.),anchor=dict(x=160.,y=117.))]
        return a,cache

    def test_reference_in_middle_tracks_both_directions_and_preserves_off_centre_anchor(self):
        a,cache=self.sequence();progress=[];result=retrack(a,cache,progress=progress.append)
        self.assertTrue(all(isinstance(p,(int,float)) and 0<=p<=1 for p in progress))
        self.assertEqual(progress,sorted(progress));self.assertEqual(progress[-1],1)
        self.assertTrue(result.track.has_data.all())
        self.assertGreater(result.perFrame[0].sharpness,0)
        for i in range(a.count):np.testing.assert_allclose(result.track.eye[i],[132+7*i,101+4*i],atol=.5)
        self.assertTrue(all(p.custom is None for p in a.perFrame),'retracking must not mutate the current project')
        restored=local_analysis(native_analysis(result))
        self.assertIsInstance(native_analysis(result)['customSeeds'][0]['anchor'],list)
        self.assertEqual(restored.customSeeds,result.customSeeds)
        np.testing.assert_allclose(restored.track.eye,result.track.eye)
        self.assertNotEqual(fingerprint(a.frames),fingerprint(a.frames,'custom'))

    def test_short_occlusion_is_marked_as_inferred_and_long_occlusion_stays_missing(self):
        a,cache=self.sequence(blank=(6,));result=retrack(a,cache)
        self.assertIsNone(result.perFrame[6].custom)
        self.assertTrue(result.track.has_data[6]);self.assertFalse(result.track.eye_visible[6]);self.assertEqual(result.track.confidence[6],.3)
        a,cache=self.sequence(blank=(5,6,7,8));result=retrack(a,cache)
        self.assertFalse(result.track.has_data[5:].any())

    def test_invalid_seeds_cancellation_and_group_boundaries(self):
        a,cache=self.sequence()
        invalid=json.loads(json.dumps(a.customSeeds[0]));invalid['anchor']['x']=0
        self.assertFalse(valid_seed(invalid,a.frames))
        with self.assertRaises(Cancelled):retrack(a,cache,cancelled=lambda:True)
        a.clips=[dict(start=0,count=4,fps=30),dict(start=4,count=5,fps=30)]
        result=retrack(a,cache)
        self.assertFalse(result.track.has_data[:4].any())
        self.assertTrue(result.track.has_data[4:].all())

if __name__=='__main__':unittest.main()
