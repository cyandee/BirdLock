"""Cancellation under real pipe backpressure, decoder failure, and subsequent exports."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from unittest.mock import patch
from types import SimpleNamespace

import numpy as np

from birdlock.core.exporter import SourceCache, VideoExporter, ExportError, ExportCancelled, _stream_frames, _remove_temporary, _output_file
from birdlock.core.paths import ffmpeg_path
from birdlock.core.render import OutputFrame
from birdlock.core.settings import ExportSettings


class ExportRecoveryTests(unittest.TestCase):
    def test_temporary_cleanup_retries_windows_sharing_lock(self):
        error = PermissionError('temporarily locked'); error.winerror = 32
        with patch('birdlock.core.exporter.IS_WINDOWS', True), \
             patch('birdlock.core.exporter.os.unlink', side_effect=[error, error, None]) as unlink, \
             patch('birdlock.core.exporter.time.sleep'):
            _remove_temporary('temporary.mp4')
        self.assertEqual(unlink.call_count, 3)

    def test_persistent_cleanup_lock_does_not_hide_cancellation_or_touch_destination(self):
        error = PermissionError('locked'); error.winerror = 32
        with tempfile.TemporaryDirectory() as td:
            destination = Path(td)/'out.mp4'; destination.write_bytes(b'older export')
            with patch('birdlock.core.exporter.IS_WINDOWS', True), \
                 patch('birdlock.core.exporter.os.unlink', side_effect=error) as unlink, \
                 patch('birdlock.core.exporter.time.sleep'), self.assertLogs('birdlock', level='WARNING'):
                with self.assertRaises(ExportCancelled):
                    with _output_file(destination, lambda:False):
                        raise ExportCancelled()
                self.assertEqual(unlink.call_count, 11)
            self.assertEqual(destination.read_bytes(), b'older export')

    def test_decoder_failure_releases_all_waiters_and_next_request_can_retry(self):
        entered, release = threading.Event(), threading.Event()
        def source(*args):
            entered.set(); release.wait(2)
            raise ValueError('invalid image')
        cache = SourceCache(SimpleNamespace(source=source), False, 1)
        errors=[]
        def get():
            try:cache.get(0)
            except Exception as e:errors.append(e)
        owner=threading.Thread(target=get,daemon=True);owner.start();self.assertTrue(entered.wait(1))
        waiter=threading.Thread(target=get,daemon=True);waiter.start();time.sleep(.03);release.set()
        owner.join(2);waiter.join(2)
        self.assertFalse(owner.is_alive());self.assertFalse(waiter.is_alive())
        self.assertEqual([str(e) for e in errors],['invalid image']*2)
        cache.job.source=lambda *a:'recovered';self.assertEqual(cache.get(0),'recovered')

    def test_decoder_timeout_is_an_error_not_an_infinite_wait(self):
        cache=SourceCache(SimpleNamespace(source=lambda *a:None),False,1)
        from concurrent.futures import Future
        failed=Future();failed.set_exception(TimeoutError('read timeout'));cache.pending[0]=failed
        with self.assertRaisesRegex(TimeoutError,'read timeout'):cache.get(0)

    def test_windows_command_length_error_explains_how_to_retry(self):
        error=OSError('filename or extension too long');error.winerror=206
        with patch('birdlock.core.exporter.subprocess.Popen',side_effect=error):
            with self.assertRaisesRegex(ExportError,'缩短保存路径'):
                _stream_frames(['ffmpeg','out.mp4'],[OutputFrame(0,0,0,1)],
                               lambda _:None,lambda _:None,lambda:False,64,64)

    def test_cancel_interrupts_blocked_encoder_pipe_and_reaps_child(self):
        with tempfile.TemporaryDirectory() as td:
            pid=Path(td)/'pid';out=Path(td)/'out.mp4'
            # Child deliberately keeps stdin open without reading; one frame exceeds the pipe.
            script="import os,time,pathlib,sys;pathlib.Path(sys.argv[1]).write_text(str(os.getpid()));time.sleep(20)"
            stop=threading.Event();errors=[]
            cmd=[sys.executable,'-c',script,str(pid),str(out)]
            def stream():
                try:_stream_frames(cmd,[OutputFrame(0,0,0,1)]*12,
                                   lambda _:np.zeros((512,512,3),np.uint8),lambda _:None,stop.is_set,512,512,2)
                except Exception as e:errors.append(e)
            worker=threading.Thread(target=stream,daemon=True);worker.start()
            limit=time.monotonic()+5
            while not pid.exists() and time.monotonic()<limit:time.sleep(.02)
            self.assertTrue(pid.exists());stop.set();worker.join(3)
            self.assertFalse(worker.is_alive(),'blocked encoder did not cancel')
            self.assertEqual(len(errors),1);self.assertIsInstance(errors[0],ExportCancelled)
            self.assertFalse(out.exists())
            # Popen.wait has reaped this exact child, not an unrelated FFmpeg process.
            if os.name!='nt':
                with self.assertRaises(ProcessLookupError):os.kill(int(pid.read_text()),0)

    @unittest.skipUnless(ffmpeg_path(),'FFmpeg required')
    def test_cancel_then_change_codec_and_export_again_in_same_process(self):
        settings=ExportSettings();settings.shortSide=64;settings.outputFPS=30;settings.encoder='software'
        class Job:
            export=settings
            export_decode_scale=1
            output_size=(64,64)
            output_frames=[OutputFrame(i,i,0,1) for i in range(45)]
            duration=1.5
            def source(self,*a):return None
            def mixed_audio(self,a):return a
            def render_output(self,of,**kwargs):return np.full((64,64,3),of.a*3,np.uint8)
        with tempfile.TemporaryDirectory() as td:
            exporter=VideoExporter(workers=2);stop=threading.Event();job=Job()
            with self.assertRaises(ExportCancelled):
                exporter.export_video(job,str(Path(td)/'cancelled.mp4'),
                    progress=lambda p:stop.set() if p>.1 else None,cancelled=stop.is_set)
            from birdlock.core.settings import VideoCodec
            for codec in (VideoCodec.HEVC,VideoCodec.H264):
                settings.codec=codec;out=Path(td)/(codec.value+'.mp4')
                exporter.export_video(job,str(out));self.assertGreater(out.stat().st_size,500)

    @unittest.skipUnless(ffmpeg_path(),'FFmpeg required')
    def test_hardware_runtime_failure_falls_back_without_name_error(self):
        settings=ExportSettings();settings.encoder='nvenc'
        job=SimpleNamespace(mixed_audio=lambda a:a,output_frames=[OutputFrame(0,0,0,1)],
                            output_size=(64,64),export=settings,export_decode_scale=1)
        exporter=VideoExporter(1)
        def pick(codec,quality,w,h,fps,preference,*args):return [],'libx264' if preference=='software' else 'h264_nvenc'
        with tempfile.TemporaryDirectory() as td,patch('birdlock.core.exporter._encoder_args',side_effect=pick),patch('birdlock.core.exporter._stream_frames',side_effect=[ExportError('driver failed'),None]) as stream:
            exporter.export_video(job,str(Path(td)/'out.mp4'))
        self.assertEqual(stream.call_count,2);self.assertEqual(exporter.encoder_used,'libx264')



class EncoderProbeTests(unittest.TestCase):
    def test_auto_stops_after_first_working_encoder_and_probes_requested_codec(self):
        from birdlock.core import gpu
        with patch.object(gpu,'IS_WINDOWS',True),patch.object(gpu,'encoder_works',return_value=True) as check:
            self.assertEqual(gpu.pick_encoder('hevc'),'hevc_nvenc')
            check.assert_called_once()
            self.assertEqual(check.call_args.args[0],'hevc_nvenc')

    def test_concurrent_identical_probes_share_one_child(self):
        from birdlock.core import gpu
        from concurrent.futures import ThreadPoolExecutor
        real_popen=subprocess.Popen;children=[]
        def spawn(*a,**kw):
            child=real_popen([sys.executable,'-c','import time;time.sleep(.2)'],**kw);children.append(child);return child
        with gpu._encoder_cache_lock:gpu._encoder_cache.clear()
        with patch.object(gpu.subprocess,'Popen',side_effect=spawn):
            with ThreadPoolExecutor(4) as pool:results=list(pool.map(lambda _:gpu.encoder_works('test-shared',64,64),range(4)))
        self.assertEqual(results,[True]*4);self.assertEqual(len(children),1)
        self.assertIsNotNone(children[0].poll())

    def test_cancelled_probe_is_reaped_not_cached_and_can_be_retried(self):
        from birdlock.core import gpu
        real_popen=subprocess.Popen;children=[];stop=threading.Event()
        def spawn(*a,**kw):
            child=real_popen([sys.executable,'-c','import time;time.sleep(20)'],**kw);children.append(child);return child
        timer=threading.Timer(.15,stop.set);timer.start();start=time.monotonic()
        with patch.object(gpu.subprocess,'Popen',side_effect=spawn):
            with self.assertRaises(gpu.EncoderProbeCancelled):gpu.encoder_works('test-cancel',64,64,stop.is_set)
        timer.join();self.assertLess(time.monotonic()-start,2);self.assertIsNotNone(children[0].poll())
        with gpu._encoder_cache_lock:self.assertNotIn(('test-cancel',64,64),gpu._encoder_cache)
        with patch.object(gpu.subprocess,'Popen',side_effect=lambda *a,**kw:real_popen([sys.executable,'-c','pass'],**kw)):
            self.assertTrue(gpu.encoder_works('test-cancel',64,64))


if __name__ == '__main__':
    unittest.main()
