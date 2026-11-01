import json
import tempfile
import unittest
from pathlib import Path

import cv2
import numpy as np

from birdlock.core.paths import ffmpeg_path
from birdlock.core.frames import load_image
from birdlock.core.lens_profile import LensProfile
from birdlock.core.video_import import extract, probe, VideoImportCancelled


class VideoImportTests(unittest.TestCase):
    @unittest.skipUnless(ffmpeg_path(), 'FFmpeg required')
    def test_full_fractional_rate_clip_keeps_the_last_sample(self):
        import subprocess
        from birdlock.core.gpu import _hidden_startupinfo
        source = self.root/'ntsc.mp4'
        images=np.stack([np.full((48,64,3),min(250,i//4),np.uint8) for i in range(840)])
        result=subprocess.run([ffmpeg_path(),'-v','error','-f','rawvideo','-pix_fmt','bgr24','-s','64x48','-r','120000/1001',
            '-i','pipe:0','-c:v','libx264','-pix_fmt','yuv420p',str(source)],input=images.tobytes(),capture_output=True,**_hidden_startupinfo())
        self.assertEqual(result.returncode,0,result.stderr)
        frames,fps=extract(source,seconds=10,fps=30,root=self.root/'fractional-cache')
        self.assertEqual(len(frames),211)
        self.assertAlmostEqual(frames[-1].captureTime,7)
        self.assertGreater(float(load_image(frames[-1]).mean()),200)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def profile(self, **updates):
        d = dict(name='Test lens', calib_dimension=dict(w=64, h=48),
                 fisheye_params=dict(camera_matrix=[[50,0,32],[0,50,24],[0,0,1]], distortion_coeffs=[.02,-.01,0,0]))
        d.update(updates)
        path = self.root/'lens.json'
        path.write_text(json.dumps(d), encoding='utf-8')
        return path

    def test_profile_coordinates_match_opencv_and_reject_wrong_modes(self):
        lens = LensProfile.load(self.profile())
        x,y = lens.maps(128,96)
        point = np.array([[[ (10-64)/100, (20-48)/100 ]]], dtype=np.float64)
        k = lens.matrix.copy();k[:2] *= 2
        expected = cv2.fisheye.distortPoints(point,k,lens.coefficients)[0,0]
        np.testing.assert_allclose([x[20,10],y[20,10]],expected,atol=1e-4)
        with self.assertRaises(ValueError): lens.maps(100,100)
        for update in [dict(distortion_model='gopro'), dict(input_horizontal_stretch=1.33),dict(digital_lens='superview'),dict(interpolations={'1':{}})]:
            with self.assertRaises(ValueError): LensProfile.load(self.profile(**update))

    @unittest.skipUnless(ffmpeg_path(), 'FFmpeg required')
    def test_actual_video_trim_sample_cache_lens_and_cancel(self):
        import subprocess
        from birdlock.core.gpu import _hidden_startupinfo
        path = self.root/'飞鸟 片段.mp4'
        images = np.stack([np.full((48,64,3),i*3,np.uint8) for i in range(30)])
        p = subprocess.run([ffmpeg_path(),'-v','error','-f','rawvideo','-pix_fmt','bgr24','-s','64x48','-r','30','-i','pipe:0',
                            '-c:v','libx264','-pix_fmt','yuv420p',str(path)],input=images.tobytes(),capture_output=True,**_hidden_startupinfo())
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual((probe(path).width,probe(path).height),(64,48))
        fr,fps=extract(path,start=.2,seconds=.6,fps=15,root=self.root/'cache')
        self.assertEqual((len(fr),fps),(9,15))
        self.assertAlmostEqual(fr[-1].captureTime,8/15)
        means=[float(load_image(f).mean()) for f in fr]
        self.assertTrue(all(b>a for a,b in zip(means,means[1:])),means)
        self.assertAlmostEqual(means[0],18,delta=5)
        again,_=extract(path,start=.2,seconds=.6,fps=15.0,root=self.root/'cache')
        self.assertEqual(fr,again)
        corrected,_=extract(path,start=.2,seconds=.6,fps=15,profile=self.profile(),root=self.root/'cache')
        self.assertNotEqual(fr[0].path,corrected[0].path)
        self.assertTrue(Path(corrected[-1].path).is_file())
        abort=[]
        with self.assertRaises(VideoImportCancelled):
            extract(path,seconds=.8,fps=30,root=self.root/'cancel',progress=lambda p:abort.append(p),cancelled=lambda:bool(abort))
        self.assertEqual(list((self.root/'cancel').iterdir()),[])
        with self.assertRaises(ValueError): extract(path,start=-1,root=self.root/'bad')
        self.assertEqual(len(list((self.root/'cache').glob('*/import.json'))),2)
