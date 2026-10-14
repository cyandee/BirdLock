"""Export (port of Export/{VideoExporter, AudioMixer}.swift) using FFmpeg.

Frames are rendered on a thread pool (decoding and OpenCV release the GIL) and streamed in order to an
FFmpeg process as raw BGR. FFmpeg encodes on the GPU when possible (NVENC / AMF / Quick Sync) and muxes
the background music in the same pass.
"""
from __future__ import annotations

import collections
import os
import subprocess
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Callable

import cv2
import numpy as np

from . import frames as F
from . import gpu
from .paths import ffmpeg_path
from .render import FlowInterpolator, OutputFrame, RenderJob
from .settings import AudioSettings, FrameInterpolation, VideoCodec


class ExportError(Exception):
    pass


class ExportCancelled(ExportError):
    def __init__(self):
        super().__init__("已取消")


def _ffmpeg() -> str:
    ff = ffmpeg_path()
    if not ff:
        raise ExportError("找不到 FFmpeg（软件目录下的 ffmpeg 文件夹缺失）")
    return ff


class SourceCache:
    """Decoded sources shared by worker threads (slow motion shows each source many times)."""

    def __init__(self, job: RenderJob, proxy: bool, scale: float, limit: int = 12):
        self.job, self.proxy, self.scale, self.limit = job, proxy, scale, limit
        self.items: collections.OrderedDict = collections.OrderedDict()
        self.events: dict[int, threading.Event] = {}
        self.lock = threading.Lock()

    def get(self, i: int):
        with self.lock:
            if i in self.items:
                self.items.move_to_end(i)
                return self.items[i]
            ev = self.events.get(i)
            mine = ev is None
            if mine:
                ev = self.events[i] = threading.Event()
        if not mine:
            ev.wait()
            with self.lock:
                return self.items.get(i)
        src = self.job.source(i, self.proxy, self.scale)
        with self.lock:
            self.items[i] = src
            while len(self.items) > self.limit:
                self.items.popitem(last=False)
            del self.events[i]
        ev.set()
        return src


def _ordered_render(job: RenderJob, frames: list[OutputFrame], render: Callable[[OutputFrame], np.ndarray | None],
                    cancelled: Callable[[], bool], workers: int):
    """Yield (index, image) in order, rendering a few frames ahead in parallel.
    Consecutive identical output frames (slow-motion holds) are rendered once."""
    window = max(2, workers * 2)
    with ThreadPoolExecutor(max_workers=workers) as ex:
        queue = collections.deque()
        it = iter(enumerate(frames))
        prev_submitted = None

        def submit() -> bool:
            nonlocal prev_submitted
            nxt = next(it, None)
            if nxt is None:
                return False
            k, of = nxt
            queue.append((k, None if of == prev_submitted else ex.submit(render, of)))
            prev_submitted = of
            return True

        for _ in range(window):
            if not submit():
                break
        last_img = None
        while queue:
            if cancelled():
                for _, f in queue:
                    if f:
                        f.cancel()
                raise ExportCancelled()
            k, fut = queue.popleft()
            if fut is not None:
                last_img = fut.result()
            submit()
            yield k, last_img


def _encoder_args(codec: VideoCodec, quality, W: int, H: int, fps: float, preference: str) -> tuple[list[str], str]:
    if codec in (VideoCodec.PRORES_422HQ, VideoCodec.PRORES_4444):
        prof = "3" if codec == VideoCodec.PRORES_422HQ else "4"
        pix = "yuv422p10le" if codec == VideoCodec.PRORES_422HQ else "yuv444p10le"
        return ["-c:v", "prores_ks", "-profile:v", prof, "-pix_fmt", pix, "-vendor", "apl0"], "prores_ks"
    fam = "h264" if codec == VideoCodec.H264 else "hevc"
    enc = gpu.pick_encoder(fam, preference)
    bpp = quality.bpp * (0.6 if fam == "hevc" else 1.0)
    br = int(W * H * fps * bpp)
    rate = ["-b:v", str(br), "-maxrate", str(int(br * 1.5)), "-bufsize", str(int(br * 2))]
    args = ["-c:v", enc]
    if enc.endswith("_nvenc"):
        args += ["-preset", "p6", "-tune", "hq", "-rc", "vbr", "-multipass", "qres", "-spatial-aq", "1"] + rate
    elif enc.endswith("_amf"):
        args += ["-quality", "quality", "-rc", "vbr_peak"] + rate
    elif enc.endswith("_qsv"):
        args += ["-preset", "slower"] + rate
    elif enc.endswith("_videotoolbox"):
        args += ["-b:v", str(br)]
    elif enc == "libx264":
        args += ["-preset", "slow"] + rate
    else:  # libx265
        args += ["-preset", "medium", "-x265-params", "log-level=error"] + rate
    args += ["-pix_fmt", "yuv420p"]
    if fam == "hevc":
        args += ["-tag:v", "hvc1"]       # plays in QuickTime / iOS
    if fam == "h264" and not enc.endswith("_videotoolbox"):
        args += ["-profile:v", "high"]
    return args, enc


def _audio_filter(s: AudioSettings, duration: float) -> str:
    fi = min(max(0.0, s.fadeIn), duration / 2)
    fo = min(max(0.0, s.fadeOut), duration - fi)
    f = [f"atrim=0:{duration:.3f}", "asetpts=PTS-STARTPTS", f"volume={max(0.0, min(2.0, s.volume)):.3f}"]
    if fi > 0.01:
        f.append(f"afade=t=in:st=0:d={fi:.3f}")
    if fo > 0.01:
        f.append(f"afade=t=out:st={duration - fo:.3f}:d={fo:.3f}")
    return ",".join(f)


def _audio_input(s: AudioSettings) -> list[str]:
    args = []
    if s.loop:
        args += ["-stream_loop", "-1"]
    args += ["-ss", f"{max(0.0, s.startOffset):.3f}", "-i", s.path]
    return args


def _run_quiet(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, **gpu._hidden_startupinfo(), **kw)


class VideoExporter:
    def __init__(self, workers: int | None = None):
        self.workers = workers or max(2, min(8, (os.cpu_count() or 4) - 1))
        self.encoder_used = ""

    def export_video(self, job: RenderJob, out: str, audio: AudioSettings | None = None,
                     progress: Callable[[float], None] = lambda p: None, cancelled: Callable[[], bool] = lambda: False):
        frames = job.output_frames
        if not frames:
            raise ExportError("没有可导出的帧")
        W, H = job.output_size
        s = job.export
        args, self.encoder_used = _encoder_args(s.codec, s.quality, W, H, s.outputFPS, s.encoder)
        cmd = [_ffmpeg(), "-y", "-hide_banner", "-loglevel", "error",
               "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", f"{W}x{H}", "-r", f"{s.outputFPS:g}", "-i", "-"]
        use_audio = audio is not None and audio.active and os.path.exists(audio.path)
        if use_audio:
            cmd += _audio_input(audio)
        # RGB -> YUV with the BT.709 matrix, tagged as BT.709
        cmd += ["-vf", "scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd",
                "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"] + args
        if use_audio:
            cmd += ["-filter_complex", f"[1:a]{_audio_filter(audio, job.duration)}[a]", "-map", "0:v", "-map", "[a]",
                    "-c:a", "aac", "-b:a", "256k"]
        cmd += ["-movflags", "+faststart", out]

        cache = SourceCache(job, proxy=not s.useFullResolution, scale=job.export_decode_scale)
        interp = FlowInterpolator() if s.interpolation == FrameInterpolation.AI else None

        def render(of):
            return job.render_output(of, fetch=cache.get, interpolate=interp)

        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                **gpu._hidden_startupinfo())
        err_tail = []
        t = threading.Thread(target=lambda: err_tail.extend(proc.stderr.read().decode("utf-8", "replace").splitlines()[-12:]),
                             daemon=True)
        t.start()
        try:
            black = np.zeros((H, W, 3), np.uint8)
            for k, img in _ordered_render(job, frames, render, cancelled, self.workers):
                if img is None or img.shape[:2] != (H, W):
                    img = black
                try:
                    proc.stdin.write(np.ascontiguousarray(img).tobytes())
                except (BrokenPipeError, OSError):
                    break
                progress((k + 1) / len(frames))
            proc.stdin.close()
            proc.wait()
            t.join(timeout=5)
        except BaseException:
            proc.kill()
            proc.wait()
            try:
                os.remove(out)
            except OSError:
                pass
            raise
        if proc.returncode != 0:
            raise ExportError("视频编码失败：" + (" ".join(err_tail[-3:]) or f"ffmpeg 退出码 {proc.returncode}"))

    def export_images(self, job: RenderJob, out_dir: str, progress=lambda p: None, cancelled=lambda: False):
        os.makedirs(out_dir, exist_ok=True)
        used = job.used
        if not used:
            raise ExportError("没有可导出的帧")
        cache = SourceCache(job, proxy=not job.export.useFullResolution, scale=job.export_decode_scale)
        frames = [OutputFrame(i, i, 0.0, 1.0) for i in used]
        for k, img in _ordered_render(job, frames, lambda of: job.render_output(of, fetch=cache.get), cancelled, self.workers):
            if img is not None:
                name = f"{k:05d}_{Path(job.analysis.frames[frames[k].a].path).stem}.jpg"
                F.write_jpeg(img, os.path.join(out_dir, name), 92)
            progress((k + 1) / len(frames))

    def export_gif(self, job: RenderJob, out: str, max_side: int = 720, progress=lambda p: None, cancelled=lambda: False):
        frames = job.output_frames
        if not frames:
            raise ExportError("没有可导出的帧")
        W, H = job.output_size
        scale = min(1.0, max_side / max(W, H))
        w, h = job.out_dims(scale)
        fps = job.export.outputFPS
        cmd = [_ffmpeg(), "-y", "-hide_banner", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "bgr24",
               "-s", f"{w}x{h}", "-r", f"{fps:g}", "-i", "-",
               "-filter_complex", "[0:v]split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a",
               "-loop", "0", out]
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                **gpu._hidden_startupinfo())
        try:
            for k, img in _ordered_render(job, frames, lambda of: job.render_output(of, scale=scale), cancelled, self.workers):
                proc.stdin.write(np.ascontiguousarray(img if img is not None else np.zeros((h, w, 3), np.uint8)).tobytes())
                progress((k + 1) / len(frames))
            proc.stdin.close()
            err = proc.stderr.read().decode("utf-8", "replace")
            proc.wait()
        except BaseException:
            proc.kill()
            raise
        if proc.returncode != 0:
            raise ExportError("GIF 导出失败：" + err.strip()[-300:])


# ---------------------------------------------------------------------------------------------- audio helpers


def audio_overview(path: str, bins_per_second: float = 40.0) -> tuple[float, np.ndarray]:
    """(duration seconds, peak level per bin) for drawing a waveform."""
    rate = 8000
    cmd = [_ffmpeg(), "-hide_banner", "-loglevel", "error", "-i", path, "-vn", "-ac", "1", "-ar", str(rate), "-f", "f32le", "-"]
    r = _run_quiet(cmd, timeout=300)
    if r.returncode != 0 or not r.stdout:
        raise ExportError(f"「{os.path.basename(path)}」里没有可用的音轨")
    x = np.abs(np.frombuffer(r.stdout, dtype=np.float32))
    b = max(1, int(rate / bins_per_second))
    n = int(np.ceil(len(x) / b))
    x = np.pad(x, (0, n * b - len(x)))
    return len(r.stdout) / 4 / rate, np.minimum(1.0, x.reshape(n, b).max(1))


def render_audio_preview(s: AudioSettings, duration: float, start: float = 0.0) -> str | None:
    """WAV of the music exactly as it will be in the video, starting at `start` seconds (for preview playback)."""
    if not s.active or duration <= 0 or not os.path.exists(s.path):
        return None
    fd, out = tempfile.mkstemp(prefix="birdlock-preview-", suffix=".wav")
    os.close(fd)
    filt = _audio_filter(s, duration) + (f",atrim=start={start:.3f},asetpts=PTS-STARTPTS" if start > 0 else "")
    cmd = [_ffmpeg(), "-y", "-hide_banner", "-loglevel", "error"] + _audio_input(s) + \
          ["-filter_complex", f"[0:a]{filt}[a]", "-map", "[a]", "-ac", "2", "-ar", "44100", out]
    r = _run_quiet(cmd, timeout=120)
    return out if r.returncode == 0 else None
