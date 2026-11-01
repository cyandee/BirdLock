import json
import math
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import cv2
import numpy as np

from birdlock.core import video_stabilization as motion
from birdlock.core.analysis import Track
from birdlock.core.frames import SourceFrame
from birdlock.core.planner import FrameXform
from birdlock.core.render import RenderJob
from birdlock.core.settings import Composition, ExportSettings, VideoStabilizationSettings
from birdlock.core.camera_metadata import CameraMetadata


def synthetic_record(n=180, fps=30):
    t=np.arange(n)/fps
    paths=[motion.similarity(10*math.sin(43*x)+12*x, 7*math.sin(59*x), .015*math.sin(31*x)) for x in t]
    steps=[[0,0,0,0,1]]
    for previous,current in zip(paths,paths[1:]):
        m=current@np.linalg.inv(previous)
        steps.append([m[0,2],m[1,2],math.atan2(m[1,0],m[0,0]),0,1])
    return dict(schema=motion.SCHEMA,width=640,height=360,fps=fps,start=0,intrinsics=[600,600,320,180],steps=steps,gyro=[]),paths


class VideoStabilizationTests(unittest.TestCase):
    def test_physical_intrinsics_are_only_estimated_from_fixed_complete_metadata(self):
        frame=dict(Default=dict(SensorWidth=31.948,SensorHeight=17.971),Lens=dict(FocalLength=600.))
        actual=motion.physical_intrinsics([frame,frame],3840,2160)
        np.testing.assert_allclose(actual,[3840*600/31.948,2160*600/17.971,1920,1080])
        zoom=dict(Default=frame['Default'],Lens=dict(FocalLength=610.))
        self.assertIsNone(motion.physical_intrinsics([frame,zoom],3840,2160))
        self.assertIsNone(motion.physical_intrinsics([frame,{}],3840,2160))
        self.assertIsNone(motion.physical_intrinsics([frame],2160,3840))

    def test_feature_registration_recovers_rotation_translation_and_rejects_blank(self):
        rng=np.random.default_rng(3); image=np.zeros((360,640),np.uint8)
        for x,y,r,v in rng.integers([35,35,2,80],[605,325,7,255],(400,4)):
            cv2.circle(image,(int(x),int(y)),int(r),int(v),-1)
        expected=motion.similarity(5,-4,.018,math.log(1.002))
        current=cv2.warpPerspective(image,expected,(640,360))
        estimated,quality=motion.image_pair(image,current)
        self.assertGreater(quality,.6)
        for point in ([80,80],[320,180],[550,290]):
            np.testing.assert_allclose(motion.apply(estimated,point),motion.apply(expected,point),atol=.2)
        rejected,quality=motion.image_pair(np.zeros_like(image),np.zeros_like(image))
        self.assertEqual(quality,0);np.testing.assert_array_equal(rejected,np.eye(3))

    def test_symmetric_visual_path_removes_jitter_and_keeps_slow_pan(self):
        data,paths=synthetic_record()
        corrections,status=motion.corrections(data,VideoStabilizationSettings())
        before=np.array([motion.apply(p,[320,180]) for p in paths])
        after=np.array([motion.apply(c@p,[320,180]) for c,p in zip(corrections,paths)])
        self.assertLess(np.std(np.diff(after,n=2,axis=0)),np.std(np.diff(before,n=2,axis=0))*.05)
        self.assertGreater(after[-20,0]-after[20,0],35)
        self.assertEqual(status['method'],'图像防抖')
        disabled,_=motion.corrections(data,VideoStabilizationSettings(strength=0))
        np.testing.assert_allclose(disabled,np.broadcast_to(np.eye(3),disabled.shape))

    def test_gyro_sync_recovers_known_offset_and_mounting_axes(self):
        fps=60;n=360;offset=.137;fx=900;center=np.array([320,180])
        def omega(t):return np.column_stack((.04*np.sin(18*t)+.02*np.sin(31*t), .03*np.sin(23*t)+.01*np.cos(41*t), .035*np.sin(15*t)+.015*np.cos(37*t)))
        optical=omega((np.arange(n-1)+.5)/fps)
        steps=[[0,0,0,0,1]]
        for x,y,z in optical:
            m=motion.similarity(angle=-z/fps)
            m[:2,2]=np.array([-y*fx/fps,x*fx/fps])+center-m[:2,:2]@center
            steps.append([m[0,2],m[1,2],-z/fps,0,1])
        times=np.arange(-.5,n/fps+1,.002)
        rates=omega(times-offset)
        imu=np.column_stack((times,-rates[:,1],-rates[:,0],-rates[:,2]))
        data=dict(schema=motion.SCHEMA,width=640,height=360,fps=fps,start=0,intrinsics=[fx,fx,*center],steps=steps,gyro=imu.tolist())
        sync=motion.synchronize(data)
        self.assertTrue(sync['valid']);self.assertGreater(sync['score'],.98)
        self.assertAlmostEqual(sync['offset'],offset,delta=.002)
        self.assertEqual(sync['axes'],[1,0,2]);self.assertEqual(sync['signs'],[-1,-1,-1])
        corrected,status=motion.corrections(data,VideoStabilizationSettings(method='gyro'))
        self.assertTrue(np.isfinite(corrected).all());self.assertEqual(status['method'],'陀螺仪防抖')
        data['gyro']=[[i*.002,0,0,0] for i in range(4000)]
        self.assertFalse(motion.synchronize(data)['valid'])
        # A single repeating oscillation has several equally plausible time/axis alignments.
        rates=omega(times-offset);rates[:,:2]=0;rates[:,2]=.04*np.sin(18*(times-offset))
        data['gyro']=np.column_stack((times,-rates[:,1],-rates[:,0],-rates[:,2])).tolist()
        data['steps']=[[0,0,0,0,1]]
        for t in (np.arange(n-1)+.5)/fps:
            angle=-.04*math.sin(18*t)/fps;m=motion.similarity(angle=angle)
            m[:2,2]=center-m[:2,:2]@center
            data['steps'].append([m[0,2],m[1,2],angle,0,1])
        self.assertFalse(motion.synchronize(data)['valid'])

    def test_missing_gyro_interval_falls_back_to_measured_image_path(self):
        data,_=synthetic_record();times=np.arange(0,6,.002)
        times=times[(times<1.2)|(times>2.5)]
        data['gyro']=[[t,0,0,.03*math.sin(12*t)] for t in times]
        settings=VideoStabilizationSettings(method='gyro',autoSync=False,smoothness=.2)
        actual,_=motion.corrections(data,settings)
        settings.method='visual';visual,_=motion.corrections(data,settings)
        np.testing.assert_allclose(actual[38:74],visual[38:74],atol=1e-10)
        self.assertTrue(np.isfinite(actual).all())

    def test_projective_render_coordinates_and_adaptive_crop_without_subject(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);data,_=synthetic_record(60)
            (root/'video-source.json').write_text('{}')
            motion.save_record(root/'motion.json',data)
            frames=[SourceFrame(i,str(root/f'video-{i:06d}.jpg'),640,360) for i in range(60)]
            zero=np.zeros(60);points=np.zeros((60,2))
            track=Track(points,points,np.ones(60)*50,zero,[None]*60,zero.astype(bool),zero.astype(bool),zero,False,True,50)
            analysis=SimpleNamespace(frames=frames)
            export=ExportSettings(shortSide=360);export.aspect.w=16;export.aspect.h=9
            plan,status=motion.compose_plan(analysis,track,Composition(),export,list(range(60)),VideoStabilizationSettings(framing='camera'))
            self.assertIsNotNone(plan);self.assertLessEqual(status['maxZoom'],1.4)
            for xf in plan.xforms:
                quad=np.asarray(xf.source_quad(640,360))
                self.assertTrue((quad>=-.02).all());self.assertTrue((quad[:,0]<=640.02).all());self.assertTrue((quad[:,1]<=360.02).all())
                np.testing.assert_allclose(xf.unmap(xf.map([123.4,95.2])),[123.4,95.2],atol=1e-7)
            # An independently placed coloured target must land at the full projective map.
            image=np.zeros((360,640,3),np.uint8);cv2.circle(image,(300,150),5,(0,0,255),-1)
            job=RenderJob.__new__(RenderJob);job.plan=plan;job.export=export;job.analysis=SimpleNamespace(count=60)
            job.composition=Composition();job.gains=np.ones((60,3))
            rendered=job.compose(25,image,1.)
            ys,xs=np.where(rendered[:,:,2]>180)
            np.testing.assert_allclose([xs.mean()+.5,ys.mean()+.5],plan.xforms[25].map([300.5,150.5]),atol=.7)

    def test_import_gyro_failure_keeps_cached_record(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);data,_=synthetic_record(20)
            (root/'video-source.json').write_text('{}');motion.save_record(root/'motion.json',data)
            frames=[SourceFrame(i,str(root/f'video-{i:06d}.jpg'),640,360) for i in range(20)]
            original=(root/'motion.json').read_bytes()
            with patch('birdlock.core.telemetry_io.read_telemetry',return_value={'samples':[]}):
                with self.assertRaises(ValueError):motion.import_gyro(frames,'empty.gcsv')
            self.assertEqual((root/'motion.json').read_bytes(),original)

    def test_invalid_motion_cache_is_remeasured_instead_of_reused(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);data,_=synthetic_record(2);data['fps']=0
            (root/'video-source.json').write_text('{}');motion.save_record(root/'motion.json',data)
            frames=[SourceFrame(i,str(root/f'video-{i:06d}.jpg'),640,360) for i in range(2)]
            for frame in frames:cv2.imwrite(frame.path,np.full((360,640,3),110,np.uint8))
            self.assertIsNone(motion.load(frames))
            with patch('birdlock.core.lens_catalog.detect',return_value=SimpleNamespace(metadata=CameraMetadata())),patch('birdlock.core.telemetry_io.read_telemetry',return_value={'samples':[]}):
                repaired=motion.prepare(frames,root/'absent.mp4',0,30)
            self.assertEqual(repaired['fps'],30);self.assertIsNotNone(motion.load(frames))

