"""Disk-backed, uniformly sampled SDR video import into the existing subject pipeline."""
from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading
from dataclasses import dataclass

import cv2
import numpy as np

from .frames import SourceFrame, ExifInfo
from .gpu import _hidden_startupinfo
from .lens_profile import LensProfile
from .paths import cache_dir, ffmpeg_path

VIDEO_EXT = {'.mp4', '.mov', '.m4v', '.avi', '.mkv'}
MAX_IMPORT_SECONDS = 600
MAX_IMPORT_FRAMES = 18_000
MAX_SAMPLE_FPS = 60
DISK_RESERVE = 512 << 20


class VideoImportCancelled(Exception):
    pass


@dataclass
class VideoInfo:
    width: int
    height: int
    fps: float
    duration: float


def probe(path) -> VideoInfo:
    tool = ffmpeg_path()
    if not tool:
        raise ValueError('视频导入需要 FFmpeg；请检查安装包是否完整')
    p = subprocess.run([tool, '-hide_banner', '-i', str(path)], capture_output=True, timeout=30, **_hidden_startupinfo())
    detail = p.stderr.decode('utf-8', errors='replace')
    if 'smpte2084' in detail or 'arib-std-b67' in detail:
        raise ValueError('实验视频导入暂只支持 SDR；请先将 HDR 转为 SDR')
    duration = re.search(r'Duration:\s*(\d+):(\d+):([\d.]+)', detail)
    lines = [s for s in detail.splitlines() if 'Video:' in s and 'attached pic' not in s]
    size = re.search(r'\b(\d{2,5})x(\d{2,5})\b', lines[0]) if lines else None
    rate = re.search(r'([\d.]+) fps', lines[0]) if lines else None
    if not duration or not size or not rate:
        raise ValueError('无法读取视频尺寸、帧率或时长；请使用常规 MP4 / MOV 视频')
    h, m, s = map(float, duration.groups())
    w, ht = map(int, size.groups())
    rotation = re.search(r'rotation of\s+(-?[\d.]+)', detail)
    if rotation and round(float(rotation[1])) % 180:
        w, ht = ht, w
    info = VideoInfo(w, ht, float(rate[1]), h * 3600 + m * 60 + s)
    if not (0 < info.fps <= 1000 and 0 < info.duration and w * ht <= 67_108_864):
        raise ValueError('视频参数超出实验导入支持范围')
    return info


def selection(info, start, seconds, fps):
    """Shared validation for the import form and the real decoder."""
    if not all(math.isfinite(v) for v in (start, seconds, fps)) or start < 0 or seconds <= 0 or not 1 <= fps <= MAX_SAMPLE_FPS or start >= info.duration:
        raise ValueError('视频片段或采样帧率无效（1–60 fps）')
    start = float(start)
    seconds = min(float(seconds), info.duration - start)
    fps = min(float(fps), info.fps)
    count = max(1, math.ceil(seconds * fps - 1e-7))
    if seconds > MAX_IMPORT_SECONDS or count > MAX_IMPORT_FRAMES:
        raise ValueError(f'每次最多 {MAX_IMPORT_SECONDS} 秒 / {MAX_IMPORT_FRAMES:,} 帧；请缩短片段或降低采样帧率')
    return seconds, fps, count


def estimated_cache_bytes(info, count, seconds):
    # Planning estimate for high-quality JPEG, plus analysis proxy headroom and
    # decoded stereo audio. Actual writes are checked against disk space below.
    return (info.width * info.height + 64 * 1024) * count + math.ceil(seconds * 48_000 * 4)


def cache_space(path):
    location = Path(path)
    while not location.exists() and location.parent != location:
        location = location.parent
    return shutil.disk_usage(location).free


def check_cache_budget(info, seconds, count, root):
    estimate = estimated_cache_bytes(info, count, seconds)
    if cache_space(root) < estimate + DISK_RESERVE:
        raise ValueError(f'视频缓存预计需要 {estimate/(1<<30):.2f} GiB；可用空间不足，请缩短片段、降低采样帧率或清理缓存')
    return estimate


def _write_recipe(directory,path,stat,info,start,seconds,fps,count,lens):
    recipe=dict(sourcePath=str(path),bytes=stat.st_size,modified=stat.st_mtime,width=info.width,height=info.height,
                start=start,seconds=seconds,fps=fps,count=count,lensJSON=lens.raw.decode('utf-8') if lens else None)
    target=directory/'video-recipe.json';tmp=target.with_suffix('.tmp')
    tmp.write_text(json.dumps(recipe,ensure_ascii=False),encoding='utf-8');os.replace(tmp,target)


def extract(path, start=0., seconds=10., fps=30., profile=None, root=None, progress=lambda p: None, cancelled=lambda: False):
    path = Path(path).resolve()
    if cancelled(): raise VideoImportCancelled()
    info = probe(path)
    start = float(start)
    seconds, fps, count = selection(info, start, seconds, fps)
    lens = LensProfile.load(profile) if profile else None
    stat = path.stat()
    identity = json.dumps([2, str(path), stat.st_size, stat.st_mtime_ns, start, seconds, fps,
                           hashlib.sha256(lens.raw).hexdigest() if lens else None], sort_keys=True).encode()
    base = Path(root) if root else cache_dir() / 'video-imports'
    base.mkdir(parents=True, exist_ok=True)
    final = base / hashlib.sha256(identity).hexdigest()[:32]
    if final.is_symlink() or final.is_junction():
        raise ValueError('视频缓存目录是链接；请选择本地缓存目录后重试')
    manifest = final / 'import.json'
    if manifest.is_file():
        d = json.loads(manifest.read_text(encoding='utf-8'))
        frames = [SourceFrame.from_dict(f) for f in d['frames']]
        if len(frames) == count and all(Path(f.path).is_file() and Path(f.path).stat().st_size > 0 for f in frames):
            from .video_source import prepare
            prepare(path, final, start, seconds, fps, count, cancelled)
            progress(1.)
            return frames, fps
    evicted=final.is_dir() and (final/'.evicted.json').is_file() and not final.is_symlink() and not final.is_junction()
    if final.exists() and not evicted:
        raise ValueError('视频缓存不完整，请清空缓存后重新导入')
    check_cache_budget(info, seconds, count, base)
    maps = lens.maps(info.width, info.height) if lens else None
    stage = Path(tempfile.mkdtemp(prefix='.extract-', dir=base))
    proc = None
    stop_watch = threading.Event()
    try:
        cmd = [ffmpeg_path(), '-hide_banner', '-loglevel', 'error', '-nostdin', '-ss', str(start), '-i', str(path),
               '-map', '0:v:0', '-an', '-sn', '-vf',
               f'fps=fps={fps:.12f}:start_time=0:round=up,tpad=stop_mode=clone:stop=1',
               '-frames:v', str(count), '-f', 'rawvideo', '-pix_fmt', 'bgr24', 'pipe:1']
        with tempfile.TemporaryFile() as errors:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=errors, **_hidden_startupinfo())
            def watch():
                while not stop_watch.wait(.1):
                    if cancelled():
                        if proc.poll() is None: proc.terminate()
                        return
            threading.Thread(target=watch, daemon=True).start()
            frames = []
            size = info.width * info.height * 3
            for i in range(count):
                if cancelled(): raise VideoImportCancelled()
                if i % 16 == 0 and shutil.disk_usage(base).free < max(DISK_RESERVE, size * 16):
                    raise ValueError('视频帧缓存磁盘空间不足；请缩短片段或清理缓存')
                data = bytearray()
                while len(data) < size:
                    block = proc.stdout.read(size - len(data))
                    if not block: break
                    data.extend(block)
                if not data: break
                if len(data) != size: raise ValueError('视频解码中断，未导入不完整片段')
                image = np.frombuffer(data, dtype=np.uint8).reshape(info.height, info.width, 3)
                if lens: image = lens.correct(image, maps)
                ok, encoded = cv2.imencode('.jpg', image, [cv2.IMWRITE_JPEG_QUALITY, 97])
                if not ok: raise ValueError('无法写入视频帧缓存')
                name = f'video-{i:06d}.jpg'
                (stage / name).write_bytes(encoded.tobytes())
                frames.append(SourceFrame(i, str(final / name), info.width, info.height, captureTime=i/fps,
                                          fileSize=len(encoded), modified=stat.st_mtime, exif=ExifInfo()))
                progress((i+1)/count)
            proc.stdout.close()
            code = proc.wait(timeout=30)
            if cancelled(): raise VideoImportCancelled()
            if code != 0 or len(frames) < count:
                errors.seek(0)
                raise ValueError(f'视频解码失败或帧数不足（{len(frames)}/{count} 帧，退出码 {code}）：' + errors.read(1200).decode('utf-8', errors='replace'))
        from .video_source import prepare
        prepare(path, stage, start, seconds, fps, count, cancelled)
        (stage / 'import.json').write_text(json.dumps({'source': path.name, 'start': start, 'seconds': seconds, 'fps': fps,
            'lens': lens.name if lens else None, 'frames': [f.to_dict() for f in frames]}, ensure_ascii=False), encoding='utf-8')
        if cancelled(): raise VideoImportCancelled()
        _write_recipe(stage,path,stat,info,start,seconds,fps,count,lens)
        if evicted:
            for name in ('motion.json',):
                if (final/name).is_file():shutil.copy2(final/name,stage/name)
            backup=final.with_name('.replaced-'+__import__('uuid').uuid4().hex)
            final.rename(backup)
            try:stage.rename(final)
            except BaseException:
                backup.rename(final);raise
            shutil.rmtree(backup)
        else:stage.rename(final)
        return frames, fps
    finally:
        stop_watch.set()
        if proc:
            if proc.poll() is None: proc.kill()
            proc.wait()
            if proc.stdout: proc.stdout.close()
        if stage.exists(): shutil.rmtree(stage)
