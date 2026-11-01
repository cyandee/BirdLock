import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import wave

import numpy as np

from birdlock.core.frames import SourceFrame
from birdlock.core.paths import ffmpeg_path
from birdlock.core.gpu import _hidden_startupinfo
from birdlock.core.render import output_frames, project_frames
from birdlock.core.settings import AudioSettings, Closeup, ExportSettings, LoopMode
from birdlock.core.video_source import prepare, original_track, arrange, resolve


class VideoAudioTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        n=np.arange(48000)
        self.samples=np.column_stack(((n*.4-12000).astype('<i2'),(n*.2+1000).astype('<i2')))
        self.write(self.root/'original-audio.wav',self.samples)
        (self.root/'video-source.json').write_text(json.dumps(dict(version=1,sourcePath='read-only.mov',start=2.5,seconds=1.,fps=10.,count=10,audioFile='original-audio.wav')))
        self.frames=[SourceFrame(i,str(self.root/f'video-{i:06d}.jpg'),64,48) for i in range(10)]

    @staticmethod
    def write(path,samples):
        with wave.open(str(path),'wb') as w:
            w.setparams((2,2,48000,0,'NONE','not compressed'));w.writeframes(samples.astype('<i2').tobytes())

    @staticmethod
    def read(path):
        with wave.open(str(path),'rb') as w:
            return np.frombuffer(w.readframes(w.getnframes()),'<i2').reshape(-1,2)

    def render(self, settings, used=None, shots=None):
        used=list(range(10)) if used is None else used
        timeline=project_frames(used,[],shots,10.,settings) if shots else output_frames(used,10.,settings)
        result=arrange(self.frames,timeline,settings.outputFPS,root=self.root/'arrangements')
        self.assertTrue(result['hasSource']);self.assertFalse(result['error'],result['error'])
        return self.read(result['path']),result,timeline

    def test_continuous_original_at_fractional_visual_sampling_and_cache(self):
        settings=ExportSettings(outputFPS=20)
        actual,result,timeline=self.render(settings)
        np.testing.assert_array_equal(actual,self.samples[:len(actual)])
        again=arrange(self.frames,timeline,settings.outputFPS,root=self.root/'arrangements')
        self.assertEqual(result,again)
        self.assertEqual(len(actual),45600)
        marker=original_track(self.frames);marker.volume=.25;marker.muted=True
        settings_audio=AudioSettings(tracks=[marker]);resolved=resolve(settings_audio,result,len(timeline)/20)
        self.assertTrue(resolved.tracks[0].videoOriginal and resolved.tracks[0].muted)
        self.assertEqual(resolved.tracks[0].volume,.25)
        self.assertNotEqual(resolved.tracks[0].path,marker.path)

    def test_reverse_trim_exclusion_pingpong_repeat_and_closeup_silence(self):
        settings=ExportSettings(outputFPS=10)
        actual,_,_=self.render(settings,used=[2,4,5,8])
        expected=np.concatenate([self.samples[i*4800:(i+1)*4800] for i in [2,4,5,8]])
        np.testing.assert_array_equal(actual,expected)
        settings.loop=LoopMode.REVERSE
        actual,_,_=self.render(settings,used=[2,4,5,8])
        np.testing.assert_array_equal(actual,expected[::-1])
        settings.loop=LoopMode.PING_PONG;settings.repeatCount=2
        actual,_,_=self.render(settings,used=[2,4])
        cell2=self.samples[9600:14400];cell4=self.samples[19200:24000]
        np.testing.assert_array_equal(actual,np.concatenate([cell2,cell4,cell2[::-1],cell4,cell2[::-1]]))
        settings.loop=LoopMode.FORWARD;settings.repeatCount=1
        actual,_,_=self.render(settings,shots=[Closeup(frame=2,endFrame=3,seconds=.2)])
        expected=self.samples.copy();expected[9600:19200]=0
        np.testing.assert_array_equal(actual,expected)

    def test_half_speed_and_fast_skip_have_continuous_source_clock(self):
        settings=ExportSettings(outputFPS=20,speed=.5)
        actual,_,_=self.render(settings)
        position=(np.arange(len(actual))+.5)*.5-.5
        expected=np.column_stack([np.interp(position,np.arange(len(self.samples)),self.samples[:,ch]) for ch in range(2)])
        np.testing.assert_allclose(actual,expected,atol=1)
        settings.outputFPS=10;settings.speed=2
        actual,_,_=self.render(settings,used=[1,3,4,8,9])
        expected=[]
        for i in [1,3,4,8,9]:
            pos=i*4800+(np.arange(2400)+.5)*2-.5
            expected.append(np.column_stack([np.interp(pos,np.arange(len(self.samples)),self.samples[:,ch]) for ch in range(2)]))
        expected.append(np.zeros((2400,2)))
        np.testing.assert_allclose(actual,np.concatenate(expected),atol=1)

    @unittest.skipUnless(ffmpeg_path(),'FFmpeg required')
    def test_final_mix_retains_fractional_duration_pcm_tail(self):
        from birdlock.core.exporter import render_audio_preview
        settings=ExportSettings(outputFPS=30)
        actual,result,timeline=self.render(settings)
        marker=original_track(self.frames)
        mixed=resolve(AudioSettings(tracks=[marker]),result,len(timeline)/settings.outputFPS)
        path=render_audio_preview(mixed,len(timeline)/settings.outputFPS)
        self.addCleanup(lambda:os.path.isfile(path) and os.unlink(path))
        rendered=self.read(path)
        np.testing.assert_array_equal(rendered,actual)

    @unittest.skipUnless(ffmpeg_path(),'FFmpeg required')
    def test_real_video_pcm_trim_and_no_audio(self):
        source=self.root/'video.mov'
        p=subprocess.run([ffmpeg_path(),'-v','error','-f','lavfi','-i','color=c=black:s=64x48:r=10:d=1',
            '-i',str(self.root/'original-audio.wav'),'-c:v','libx264','-c:a','pcm_s16le','-shortest',str(source)],capture_output=True,**_hidden_startupinfo())
        self.assertEqual(p.returncode,0,p.stderr)
        stage=self.root/'clip'
        info=prepare(source,stage,.2,.6,10,6)
        self.assertEqual(info['audioFile'],'original-audio.wav')
        np.testing.assert_array_equal(self.read(stage/'original-audio.wav'),self.samples[9600:38400])
        no_audio=self.root/'no-audio.mp4'
        p=subprocess.run([ffmpeg_path(),'-v','error','-i',str(source),'-an','-c:v','copy',str(no_audio)],capture_output=True,**_hidden_startupinfo())
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertIsNone(prepare(no_audio,self.root/'silent',0,1,10,10)['audioFile'])
