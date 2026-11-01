import tempfile,unittest,math
from pathlib import Path
from types import SimpleNamespace
import numpy as np
from birdlock.core import video_stabilization as m
from birdlock.core.analysis import Track
from birdlock.core.frames import SourceFrame
from birdlock.core.settings import Composition,ExportSettings,AspectRatio,VideoStabilizationSettings,EdgeFill
from birdlock.core.resource_budget import workers
from birdlock.core.lens_catalog import search,entries

class IterationStabilityTests(unittest.TestCase):
    def fixture(self,root,amplitude=35,scaling=True):
        n=120;center=np.array([960.,540.]);poses=[];steps=[[0,0,0,0,1]]
        for i in range(n):
            scale=math.exp(.10*math.sin(i*.18)) if scaling else 1
            h=m.similarity(amplitude*math.sin(i*.8),12*math.cos(i),log_scale=math.log(scale))
            h[:2,2]+=center-h[:2,:2]@center;poses.append(h)
            if i:
                delta=h@np.linalg.inv(poses[i-1]);steps.append([delta[0,2],delta[1,2],0,math.log(delta[0,0]),1])
        points=np.array([m.apply(h,center) for h in poses]);sizes=np.array([80*h[0,0]*(1+.35*math.sin(i*1.7)) for i,h in enumerate(poses)])
        track=Track(points,points,sizes,np.zeros(n),[None]*n,np.ones(n,bool),np.ones(n,bool),np.ones(n),False,True,80)
        (root/'video-source.json').write_text('{}')
        data=dict(schema=m.SCHEMA,width=1920,height=1080,fps=30,start=0,intrinsics=[1800,1800,960,540],steps=steps,gyro=[])
        m.save_record(root/'motion.json',data)
        frames=[SourceFrame(i,str(root/f'video-{i:06d}.jpg'),1920,1080) for i in range(n)]
        return SimpleNamespace(frames=frames),track,poses,data

    def test_subject_size_rejects_detection_breathing_and_camera_scale(self):
        with tempfile.TemporaryDirectory() as temp:
            a,track,poses,data=self.fixture(Path(temp));settings=VideoStabilizationSettings(maxZoom=6)
            plan,status=m.compose_plan(a,track,Composition(),ExportSettings(aspect=AspectRatio(16,9,'16:9'),shortSide=720),list(range(120)),settings)
            lengths=[]
            for h,xf in zip(poses,plan.xforms):lengths.append(np.linalg.norm(xf.map(m.apply(h,[1040,540]))-xf.map(m.apply(h,[960,540]))))
            self.assertLess(np.std(lengths)/np.mean(lengths),.015)

    def test_more_crop_preserves_stronger_motion_correction(self):
        with tempfile.TemporaryDirectory() as temp:
            a,track,poses,data=self.fixture(Path(temp),amplitude=720,scaling=False)
            export=ExportSettings(aspect=AspectRatio(16,9,'16:9'),shortSide=360)
            settings=VideoStabilizationSettings(framing='camera',maxZoom=1.4)
            _,small=m.compose_plan(a,track,Composition(),export,list(range(120)),settings)
            settings.maxZoom=8
            plan,large=m.compose_plan(a,track,Composition(),export,list(range(120)),settings)
            self.assertTrue(small['limited']);self.assertFalse(large['limited']);self.assertGreater(large['maxZoom'],2.5)
            self.assertLess(np.ptp([x.z for x in plan.xforms]),1e-10)
            for x in plan.xforms:
                quad=np.asarray(x.source_quad(640,360));self.assertTrue((quad>=-.02).all());self.assertTrue((quad[:,0]<=1920.02).all())

    def test_search_and_memory_budget(self):
        catalog=entries();self.assertEqual(len(catalog),383)
        self.assertTrue(search('索尼 FX3',catalog));self.assertEqual(search('not-a-camera-xyz',catalog),[])
        self.assertTrue(any('Sony' in x.cameraBrand for x in search('SONY',catalog)))
        self.assertEqual(workers(cpu=2,memory=4<<30),1)
        self.assertGreater(workers(cpu=64,memory=128<<30),8)
        self.assertEqual(workers(bytes_per_task=500<<20,cpu=64,memory=8<<30),1)

    def test_limited_correction_keeps_the_subject_anchor(self):
        with tempfile.TemporaryDirectory() as temp:
            a,track,poses,data=self.fixture(Path(temp),amplitude=900,scaling=False)
            composition=Composition(framing=3,edgeFill=EdgeFill.BLACK,autoLeadRoom=False)
            export=ExportSettings(aspect=AspectRatio(16,9,'16:9'),shortSide=360)
            plan,status=m.compose_plan(a,track,composition,export,list(range(120)),VideoStabilizationSettings(maxZoom=1.4))
            points=np.array([xf.map(p) for xf,p in zip(plan.xforms,track.eye)])
            self.assertTrue(status['limited']);self.assertLess(np.max(np.std(points,axis=0)),1e-6)
