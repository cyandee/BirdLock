"""Original video audio, normalized once and mapped continuously through the finished edit."""
from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import wave

import numpy as np

from .gpu import _hidden_startupinfo
from .paths import ffmpeg_path, cache_dir
from .settings import AudioTrack

RATE = 48000
MANIFEST = 'video-source.json'
AUDIO_FILE = 'original-audio.wav'


def _cancelled(cancelled):
    if cancelled():
        from .video_import import VideoImportCancelled
        raise VideoImportCancelled()


def prepare(video_path, stage_directory, start, seconds, fps, count, cancelled=lambda: False):
    """Call before the video frame stage is published. Source media remains read-only."""
    _cancelled(cancelled)
    root = Path(stage_directory)
    root.mkdir(parents=True, exist_ok=True)
    if not all(math.isfinite(float(x)) for x in (start, seconds, fps)) or start < 0 or not 0 < seconds <= 600 or fps <= 0:
        raise ValueError('视频原声片段参数无效')
    metadata = dict(version=1, sourcePath=str(Path(video_path).resolve()), start=float(start), seconds=float(seconds),
                    fps=float(fps), count=int(count), audioFile=None)
    target = root / MANIFEST
    if target.is_file():
        try:
            old = json.loads(target.read_text(encoding='utf-8'))
            if all(old.get(k) == metadata[k] for k in metadata if k != 'audioFile') and (not old.get('audioFile') or (root/AUDIO_FILE).is_file()):
                return old
        except (OSError, ValueError): pass
    tool = ffmpeg_path()
    if not tool: raise ValueError('视频原声导入需要 FFmpeg')
    probe = subprocess.run([tool, '-hide_banner', '-i', str(video_path)], capture_output=True, timeout=30, **_hidden_startupinfo())
    if b'Audio:' in probe.stderr:
        cmd = [tool, '-hide_banner', '-loglevel', 'error', '-nostdin', '-ss', str(float(start)), '-i', str(video_path),
               '-t', str(float(seconds)), '-map', '0:a:0', '-vn', '-sn', '-af', 'aresample=48000:async=1:first_pts=0',
               '-ac', '2', '-ar', str(RATE), '-f', 's16le', 'pipe:1']
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **_hidden_startupinfo())
        done = threading.Event()
        def watch():
            while not done.wait(.1):
                if cancelled():
                    if proc.poll() is None: proc.terminate()
                    return
        threading.Thread(target=watch, daemon=True).start()
        try:
            data, errors = proc.communicate(timeout=max(60, seconds*3))
            _cancelled(cancelled)
            if proc.returncode: raise ValueError('无法读取视频原声：'+errors.decode('utf-8', errors='replace')[-1000:])
        finally:
            done.set()
            if proc.poll() is None: proc.kill()
            proc.wait()
        samples = round(seconds*RATE)
        data = data[:samples*4].ljust(samples*4, b'\0')
        temporary = root / (AUDIO_FILE+'.part')
        try:
            with wave.open(str(temporary), 'wb') as w:
                w.setparams((2,2,RATE,0,'NONE','not compressed')); w.writeframes(data)
            _cancelled(cancelled)
            os.replace(temporary, root/AUDIO_FILE)
        finally:
            temporary.unlink(missing_ok=True)
        metadata['audioFile'] = AUDIO_FILE
    _cancelled(cancelled)
    temporary = root / (MANIFEST+'.part')
    temporary.write_text(json.dumps(metadata, ensure_ascii=False), encoding='utf-8')
    os.replace(temporary, target)
    return metadata


def _reference(frame):
    directory = Path(frame.path).parent
    for root in (directory, directory.parent):
        path = root/MANIFEST
        if not path.is_file(): continue
        try:
            d = json.loads(path.read_text(encoding='utf-8'))
            if d.get('version') != 1 or not math.isfinite(float(d['fps'])) or d['fps'] <= 0: return None
            if d.get('audioFile') not in (None, AUDIO_FILE): raise ValueError('视频原声缓存路径无效')
            match = re.search(r'(\d+)\.[^.]+$', Path(frame.path).name)
            ordinal = int(match[1]) if match else frame.id
            if not 0 <= ordinal < d['count']: raise ValueError('视频原声帧编号无效')
            return root, d, ordinal
        except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
            raise ValueError('视频原声缓存损坏，请重新导入视频') from error
    return None


def original_path(frames):
    """Return the original video for user-facing names, including clips without sound."""
    if not frames: return None
    try:
        ref = _reference(frames[0])
        return ref[1].get('sourcePath') if ref else None
    except (OSError, ValueError, TypeError): return None


def original_track(frames):
    """One visible marker track; mixed_audio replaces its content, preserving user volume/mute."""
    for frame in frames:
        ref = _reference(frame)
        if ref and ref[1].get('audioFile'):
            return AudioTrack(path=str(ref[0]/AUDIO_FILE), videoOriginal=True, volume=1, loop=False, fadeIn=0, fadeOut=0)
    return None


def arrange(frames, output_frames, output_fps, root=None):
    """Return {path,error,hasSource}. Run in RenderJob construction, never from audio playback."""
    has_source = any((directory/MANIFEST).is_file() for frame in frames for directory in (Path(frame.path).parent,Path(frame.path).parent.parent))
    try:
        refs = [_reference(frame) for frame in frames]
        has_source = any(r and r[1].get('audioFile') for r in refs)
        if not has_source: return dict(path=None, error='', hasSource=False)
        segments, sources = [], {}
        for frame in output_frames:
            at = frame.time
            for index, a, b, seconds in frame.sourceAudio:
                ref = refs[index]
                if ref and ref[1].get('audioFile'):
                    directory, metadata, ordinal = ref
                    path = directory/AUDIO_FILE
                    if not path.is_file(): raise ValueError('缓存中的视频原声缺失，请重新导入视频')
                    key = str(path)
                    if key not in sources:
                        st = path.stat();sources[key] = [st.st_size, st.st_mtime_ns]
                    start, end = (ordinal+a)/metadata['fps'], (ordinal+b)/metadata['fps']
                    rate = (end-start)/seconds
                    if segments and segments[-1][0] == key and abs(segments[-1][3]+segments[-1][4]-at)<1e-7 and abs(segments[-1][2]-start)<1e-7 and abs((segments[-1][2]-segments[-1][1])/segments[-1][4]-rate)<1e-7:
                        segments[-1][2] = end; segments[-1][4] += seconds
                    else: segments.append([key,start,end,at,seconds])
                at += seconds
        count = round(len(output_frames)/output_fps*RATE)
        if count*4 > 0xffffffff-36: raise ValueError('视频原声音轨过长，请减少重复次数')
        identity = json.dumps([2, count, sources, segments], sort_keys=True, separators=(',', ':')).encode()
        folder = (Path(root) if root else cache_dir())/'video-audio'
        folder.mkdir(parents=True, exist_ok=True)
        final = folder/(hashlib.sha256(identity).hexdigest()+'.wav')
        if final.is_file() and final.stat().st_size == 44+count*4:
            return dict(path=str(final),error='',hasSource=True)
        decoded = {}
        for key in sources:
            with wave.open(key, 'rb') as w:
                if (w.getnchannels(),w.getsampwidth(),w.getframerate()) != (2,2,RATE): raise ValueError('视频原声缓存格式无效，请重新导入视频')
                decoded[key] = np.frombuffer(w.readframes(w.getnframes()),dtype='<i2').reshape(-1,2)
        handle, temporary_name = tempfile.mkstemp(prefix='.original-',suffix='.wav',dir=folder)
        os.close(handle);temporary=Path(temporary_name)
        try:
            with wave.open(str(temporary),'wb') as w:
                w.setparams((2,2,RATE,0,'NONE','not compressed'))
                cursor = 0
                def silence(n):
                    while n:
                        step=min(n,32768);w.writeframesraw(bytes(step*4));n-=step
                for key, a, b, at, seconds in segments:
                    first, stop = max(cursor,round(at*RATE)), min(count,round((at+seconds)*RATE))
                    if first > cursor: silence(first-cursor)
                    data=decoded[key]
                    for k in range(first,stop,32768):
                        end=min(stop,k+32768)
                        position=a*RATE+((np.arange(k,end)+.5)/RATE-at)/seconds*(b-a)*RATE-.5
                        lo=np.floor(position).astype(np.int64);alpha=position-lo
                        valid=(position >= -.500001)&(position < len(data)-.499999)
                        sample=data[np.clip(lo,0,len(data)-1)].astype(np.float64)*(1-alpha[:,None])+data[np.clip(lo+1,0,len(data)-1)].astype(np.float64)*alpha[:,None]
                        sample[~valid]=0
                        w.writeframesraw(np.clip(np.rint(sample),-32768,32767).astype('<i2').tobytes())
                    cursor=stop
                if cursor < count: silence(count-cursor)
            os.replace(temporary,final)
        finally: temporary.unlink(missing_ok=True)
        return dict(path=str(final),error='',hasSource=True)
    except Exception as error:
        return dict(path=None,error=str(error),hasSource=has_source)


def resolve(settings, arrangement, duration):
    result=settings.copy();tracks=[]
    for layer in result.tracks:
        if not layer.videoOriginal:
            tracks.append(layer);continue
        if not arrangement['hasSource']: continue
        layer.path=arrangement['path'] or layer.path
        layer.assetID='';layer.startOffset=layer.timelineStart=0;layer.duration=duration;layer.loop=False;layer.muteRanges=[]
        layer.arrangementError=arrangement['error']
        tracks.append(layer)
    result.tracks=tracks
    return result
