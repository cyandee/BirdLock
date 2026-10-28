"""Export (port of Export/{VideoExporter, AudioMixer}.swift) using FFmpeg.

Frames are rendered on a thread pool (decoding and OpenCV release the GIL) and streamed in order to an
FFmpeg process as raw BGR. FFmpeg encodes on the GPU when possible (NVENC / AMF / Quick Sync) and muxes
the background music in the same pass.
"""
from __future__ import annotations

import collections
import os
import re
import subprocess
import tempfile
import threading
import time
from concurrent.futures import Future, ThreadPoolExecutor, TimeoutError as FutureTimeout
from contextlib import contextmanager
from pathlib import Path
from typing import Callable

import cv2
import numpy as np

from . import frames as F
from . import gpu
from .log import log
from .paths import ffmpeg_path, IS_WINDOWS
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

    def __init__(self, job: RenderJob, proxy: bool, scale: float, limit: int = 12, cancelled=lambda: False):
        self.job, self.proxy, self.scale, self.limit = job, proxy, scale, limit
        self.items: collections.OrderedDict = collections.OrderedDict()
        self.pending: dict[int, Future] = {}
        self.cancelled = cancelled
        self.lock = threading.Lock()

    def get(self, i: int):
        with self.lock:
            if i in self.items:
                self.items.move_to_end(i)
                return self.items[i]
            future = self.pending.get(i)
            mine = future is None
            if mine:
                future = self.pending[i] = Future()
        if not mine:
            while not self.cancelled():
                try:
                    return future.result(timeout=.1)
                except FutureTimeout:
                    if future.done():
                        raise
                    continue
            raise ExportCancelled()
        try:
            if self.cancelled():
                raise ExportCancelled()
            src = self.job.source(i, self.proxy, self.scale)
            with self.lock:
                self.items[i] = src
                while len(self.items) > self.limit:
                    self.items.popitem(last=False)
            future.set_result(src)
            return src
        except BaseException as error:
            future.set_exception(error)
            raise
        finally:
            with self.lock:
                self.pending.pop(i, None)


def _ordered_render(frames: list[OutputFrame], render: Callable[[OutputFrame], np.ndarray | None],
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
                while True:
                    if cancelled():
                        raise ExportCancelled()
                    try:
                        last_img = fut.result(timeout=.1)
                        break
                    except FutureTimeout:
                        if fut.done():
                            raise
                        continue
            submit()
            yield k, last_img


def _encoder_args(codec: VideoCodec, quality, W: int, H: int, fps: float, preference: str,
                  cancelled=lambda: False) -> tuple[list[str], str]:
    if codec in (VideoCodec.PRORES_422HQ, VideoCodec.PRORES_4444):
        prof = "3" if codec == VideoCodec.PRORES_422HQ else "4"
        pix = "yuv422p10le" if codec == VideoCodec.PRORES_422HQ else "yuv444p10le"
        return ["-c:v", "prores_ks", "-profile:v", prof, "-pix_fmt", pix, "-vendor", "apl0"], "prores_ks"
    fam = "h264" if codec == VideoCodec.H264 else "hevc"
    try:
        enc = gpu.pick_encoder(fam, preference, W, H, cancelled)
    except gpu.EncoderProbeCancelled:
        raise ExportCancelled() from None
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
    # On Windows, avoid the observed delayed-track collapse when short demuxers reach EOF.
    # _audio_plan limits non-looping tracks to their remaining source duration before padding;
    # keeping the decoder alive does not repeat their audible content.
    args = ["-stream_loop", "-1"] if s.loop or IS_WINDOWS else []
    args += ["-ss", f"{max(0.0, s.startOffset):.3f}", "-i", s.source_path]
    return args


_audio_lengths = {}

def _source_duration(path):
    stat = os.stat(path)
    key = (path, stat.st_mtime_ns, stat.st_size)
    if key not in _audio_lengths:
        r = _run_quiet([_ffmpeg(), "-hide_banner", "-i", path], timeout=20)
        match = re.search(rb"Duration: (\d+):(\d+):([\d.]+)", r.stderr)
        if not match:
            raise ExportError("无法读取音频时长：" + os.path.basename(path))
        h, m, sec = map(float, match.groups())
        _audio_lengths[key] = h * 3600 + m * 60 + sec
    return _audio_lengths[key]


def _audio_plan(settings, duration, first_input=0):
    layers = [t for t in settings.arranged_tracks if t.timelineStart < duration]
    from .closeup_audio import gain as mix_gain
    gain = mix_gain(layers,duration)
    inputs, filters, labels = [], [], []
    for i, layer in enumerate(layers):
        path = layer.source_path
        if not path or not os.path.isfile(path):
            raise ExportError("找不到音频：" + (layer.assetID or os.path.basename(layer.path)))
        music_duration = _source_duration(path)
        if not np.isfinite(music_duration) or music_duration <= 0.001:
            raise ExportError("音频没有可用的时长：" + os.path.basename(path))
        start = max(0, layer.timelineStart)
        span = min(duration - start, layer.duration) if layer.duration > 0 else duration - start
        track = layer.copy()
        track.startOffset = min(max(0, track.startOffset), max(0, music_duration - 0.001))
        if not track.loop:
            span = min(span, music_duration - track.startOffset)
        track.volume = max(0, min(2, track.volume)) * gain
        inputs += _audio_input(track)
        label = f"layer{i}"
        filters.append(f"[{first_input + i}:a]" + _audio_filter(track, span) +
                       f",adelay={start * 1000:.3f}:all=1,apad,atrim=0:{duration:.6f}[{label}]")
        labels.append(f"[{label}]")
    if not labels:
        return [], "", None
    filters.append("".join(labels) + f"amix=inputs={len(labels)}:normalize=0:duration=longest,atrim=0:{duration:.6f}[a]")
    return inputs, ";".join(filters), "[a]"


def _run_quiet(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, **gpu._hidden_startupinfo(), **kw)


def _remove_temporary(path):
    # Windows can briefly retain a sharing lock after the encoder exits (e.g. file
    # scanning). Cleanup must not replace ExportCancelled with a PermissionError.
    for attempt in range(11):
        try:
            os.unlink(path)
            return
        except FileNotFoundError:
            return
        except OSError as error:
            if IS_WINDOWS and getattr(error, 'winerror', None) in (32, 33) and attempt < 10:
                time.sleep(.05)
                continue
            log.warning("could not remove export temporary file %s: %s", path, error)
            return


@contextmanager
def _output_file(out, cancelled):
    """Publish only a finished file; cancelling must not remove an older export."""
    if cancelled():
        raise ExportCancelled()
    destination = Path(out)
    fd, temporary = tempfile.mkstemp(prefix=".BirdLock-export-", suffix=destination.suffix,
                                     dir=str(destination.absolute().parent))
    os.close(fd)
    try:
        yield temporary
        if cancelled():
            raise ExportCancelled()
        os.replace(temporary, out)
    finally:
        _remove_temporary(temporary)


def _stream_frames(cmd: list[str], frames: list[OutputFrame], render, progress, cancelled, W: int, H: int,
                   workers: int | None = None):
    """Render all frames and pipe them into an ffmpeg process. Raises ExportError on failure."""
    if cancelled():
        raise ExportCancelled()
    try:
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                **gpu._hidden_startupinfo())
    except OSError as error:
        if getattr(error, "winerror", None) == 206:
            raise ExportError("导出路径或音轨命令过长，请缩短保存路径，或减少音轨和重复次数后重试。") from error
        raise
    err_tail = collections.deque(maxlen=12)
    finished = threading.Event()

    def drain():
        for line in iter(proc.stderr.readline, b""):
            err_tail.append(line.decode("utf-8", "replace").strip())

    def watch_cancel():
        # A full Windows pipe can block write(), and FFmpeg can stall while finalizing.
        # Kill from another thread so cancellation can unblock either operation.
        while not finished.wait(.05):
            if cancelled():
                try:
                    proc.kill()
                except OSError:
                    pass
                return

    t = threading.Thread(target=drain, daemon=True)
    watcher = threading.Thread(target=watch_cancel, daemon=True)
    t.start()
    watcher.start()
    try:
        black = np.zeros((H, W, 3), np.uint8)
        for k, img in _ordered_render(frames, render, cancelled, workers or VideoExporter.workers_default()):
            if img is None or img.shape[:2] != (H, W):
                img = black
            try:
                proc.stdin.write(np.ascontiguousarray(img).tobytes())
            except (BrokenPipeError, OSError):
                break
            progress((k + 1) / len(frames))
        try:
            proc.stdin.close()
        except (BrokenPipeError, OSError):
            pass
        proc.wait()
        t.join(timeout=5)
        if cancelled():
            raise ExportCancelled()
    except BaseException:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        raise
    finally:
        finished.set()
        watcher.join(timeout=1)
        # Close only after the child has exited, so buffered stdin cannot block.
        try:
            proc.stdin.close()
        except OSError:
            pass
        t.join(timeout=5)
        proc.stderr.close()
    if proc.returncode != 0:
        raise ExportError("视频编码失败：" + (" ".join(list(err_tail)[-3:]) or f"ffmpeg 退出码 {proc.returncode}"))


class VideoExporter:
    def __init__(self, workers: int | None = None):
        self.workers = workers or max(2, min(8, (os.cpu_count() or 4) - 1))
        self.encoder_used = ""
        VideoExporter._default_workers = self.workers

    @staticmethod
    def workers_default() -> int:
        return getattr(VideoExporter, "_default_workers", None) or max(2, min(8, (os.cpu_count() or 4) - 1))

    def export_video(self, job: RenderJob, out: str, audio: AudioSettings | None = None,
                     progress: Callable[[float], None] = lambda p: None, cancelled: Callable[[], bool] = lambda: False):
        with _output_file(out, cancelled) as temporary:
            self._export_video(job, temporary, audio, progress, cancelled)

    def _export_video(self, job, out, audio, progress, cancelled):
        if cancelled():
            raise ExportCancelled()
        audio = job.mixed_audio(audio)
        frames = job.output_frames
        if not frames:
            raise ExportError("没有可导出的帧")
        W, H = job.output_size
        s = job.export

        cache = SourceCache(job, proxy=not s.useFullResolution, scale=job.export_decode_scale, cancelled=cancelled)
        interp = FlowInterpolator() if s.interpolation == FrameInterpolation.AI else None

        def render(of):
            return job.render_output(of, fetch=cache.get, interpolate=interp)

        def build_cmd(preference: str) -> tuple[list[str], list[str]]:
            args, self.encoder_used = _encoder_args(s.codec, s.quality, W, H, s.outputFPS, preference, cancelled)
            cmd = [_ffmpeg(), "-y", "-hide_banner", "-loglevel", "error",
                   "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", f"{W}x{H}", "-r", f"{s.outputFPS:g}", "-i", "-"]
            audio_inputs, audio_graph, audio_label = _audio_plan(audio, job.duration, 1) if audio and audio.active else ([], "", None)
            use_audio = audio_label is not None
            cmd += audio_inputs
            # RGB -> YUV with the BT.709 matrix, tagged as BT.709
            cmd += ["-vf", "scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd",
                    "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"] + args
            if use_audio:
                cmd += ["-filter_complex", audio_graph, "-map", "0:v", "-map", "[a]",
                        "-c:a", "aac", "-b:a", "256k"]
            cmd += ["-movflags", "+faststart", out]
            return cmd, args

        # hardware encoders can fail at runtime even after passing the small probe (driver limits,
        # portrait sizes, ...): automatically fall back to software encoding so the export always succeeds
        preference = s.encoder
        while True:
            cmd, args = build_cmd(preference)
            try:
                _stream_frames(cmd, frames, render, progress, cancelled, W, H, self.workers)
                return
            except ExportError as e:
                hardware = self.encoder_used.endswith(("_nvenc", "_amf", "_qsv", "_videotoolbox"))
                if hardware and preference != "software" and not cancelled():
                    log.warning("hardware encoder %s failed (%s); retrying with software encoder", self.encoder_used, e)
                    preference = "software"
                    continue
                raise

    def export_images(self, job: RenderJob, out_dir: str, progress=lambda p: None, cancelled=lambda: False):
        os.makedirs(out_dir, exist_ok=True)
        used = job.used
        if not used:
            raise ExportError("没有可导出的帧")
        cache = SourceCache(job, proxy=not job.export.useFullResolution, scale=job.export_decode_scale, cancelled=cancelled)
        frames = [OutputFrame(i, i, 0.0, 1.0) for i in used]
        for k, img in _ordered_render(frames, lambda of: job.render_output(of, fetch=cache.get), cancelled, self.workers):
            if img is not None:
                name = f"{k:05d}_{Path(job.analysis.frames[frames[k].a].path).stem}.jpg"
                F.write_jpeg(img, os.path.join(out_dir, name), 92)
            progress((k + 1) / len(frames))

    def export_gif(self, job: RenderJob, out: str, max_side: int = 720, progress=lambda p: None, cancelled=lambda: False):
        with _output_file(out, cancelled) as temporary:
            self._export_gif(job, temporary, max_side, progress, cancelled)

    def _export_gif(self, job, out, max_side, progress, cancelled):
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
        _stream_frames(cmd, frames, lambda of: job.render_output(of, scale=scale),
                       progress, cancelled, w, h, self.workers)


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
    if not s.active or duration <= 0 or start >= duration:
        return None
    inputs, graph, label = _audio_plan(s, duration)
    if label is None:
        return None
    fd, out = tempfile.mkstemp(prefix="birdlock-preview-", suffix=".wav")
    os.close(fd)
    if start > 0:
        graph += f";[a]atrim=start={start:.6f},asetpts=PTS-STARTPTS[preview]"
        label = "[preview]"
    cmd = [_ffmpeg(), "-y", "-hide_banner", "-loglevel", "error"] + inputs + [
        "-filter_complex", graph, "-map", label, "-ac", "2", "-ar", "48000", out]
    try:
        r = _run_quiet(cmd, timeout=120)
        if r.returncode != 0:
            raise ExportError("混音失败：" + r.stderr.decode("utf-8", "replace")[-500:])
        return out
    except Exception:
        os.unlink(out)
        raise
