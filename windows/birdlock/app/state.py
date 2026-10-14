"""Application state (port of BirdLockApp/AppState.swift + PreviewEngine.swift).

All heavy work runs on background threads; results come back to the Qt main thread through signals.
Widgets listen to `changed(topic)` and refresh what they show.
"""
from __future__ import annotations

import collections
import json
import math
import os
import shutil
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

import cv2
import numpy as np
from PySide6.QtCore import QObject, QTimer, Signal
from PySide6.QtGui import QImage

from ..core import frames as F
from ..core import gpu, render
from ..core.log import log
from ..core.analysis import Analyzer, Cancelled, ProxyCache, SequenceAnalysis, build_track, fingerprint
from ..core.exporter import ExportCancelled, VideoExporter, audio_overview, render_audio_preview
from ..core.models import BirdModels
from ..core.paths import IS_MAC, IS_WINDOWS, data_dir
from ..core.render import OutputFrame, RenderJob
from ..core.settings import (FRAMING_RANGE, PRESETS, AudioSettings, Composition, EdgeFill, ExportSettings, FrameSelection,
                             LookSettings, WatermarkSettings)
from ..core.util import clamp, decode_scale

AUDIO_EXT = {".mp3", ".m4a", ".aac", ".wav", ".aif", ".aiff", ".flac", ".ogg", ".wma", ".mp4", ".mov", ".m4v"}


def is_audio_file(p: str) -> bool:
    ext = Path(p).suffix.lower()
    return ext in AUDIO_EXT and ext not in F.SUPPORTED_EXT


def to_qimage(img: np.ndarray) -> QImage:
    img = np.ascontiguousarray(img)
    h, w = img.shape[:2]
    if img.ndim == 2:
        return QImage(img.data, w, h, w, QImage.Format_Grayscale8).copy()
    return QImage(img.data, w, h, w * 3, QImage.Format_BGR888).copy()


class CancelFlag:
    def __init__(self):
        self._e = threading.Event()

    def cancel(self):
        self._e.set()

    @property
    def cancelled(self) -> bool:
        return self._e.is_set()


class LatestOnly:
    """A worker thread that only runs the most recently submitted job."""

    def __init__(self, name: str):
        self._cv = threading.Condition()
        self._job = None
        threading.Thread(target=self._run, name=name, daemon=True).start()

    def submit(self, fn):
        with self._cv:
            self._job = fn
            self._cv.notify()

    def _run(self):
        while True:
            with self._cv:
                while self._job is None:
                    self._cv.wait()
                fn, self._job = self._job, None
            try:
                fn()
            except Exception as e:  # keep the worker alive
                print("preview error:", e, file=sys.stderr)


class PreviewEngine:
    """Renders preview frames off the main thread from cached proxies; sharper renders from the originals
    (decoded at just the resolution needed) run on a separate worker so they never hold up scrubbing."""

    def __init__(self):
        self.fast = LatestOnly("preview")
        self.sharp = LatestOnly("preview-hires")
        self._lock = threading.Lock()
        self._proxies: collections.OrderedDict = collections.OrderedDict()
        self._originals: collections.OrderedDict = collections.OrderedDict()

    def proxy(self, job: RenderJob, i: int):
        key = (job.analysis.fingerprint, i)
        with self._lock:
            if key in self._proxies:
                self._proxies.move_to_end(key)
                return self._proxies[key]
        p = job.cache.load_proxy(job.analysis.fingerprint, i)
        if p is None:
            return None
        with self._lock:
            self._proxies[key] = p
            while len(self._proxies) > 40:
                self._proxies.popitem(last=False)
        return p

    def original(self, job: RenderJob, i: int, scale: float):
        key = (job.analysis.fingerprint, i, scale)
        with self._lock:
            if key in self._originals:
                self._originals.move_to_end(key)
                return self._originals[key]
        r = job.source(i, False, scale)
        if r is None:
            return None
        with self._lock:
            self._originals[key] = r
            total = sum(v[0].nbytes for v in self._originals.values())
            while total > 900 << 20 and len(self._originals) > 1:
                _, v = self._originals.popitem(last=False)
                total -= v[0].nbytes
        return r

    def proxy_source(self, job: RenderJob, i: int):
        p = self.proxy(job, i)
        if p is None:
            return None
        return p, p.shape[1] / job.analysis.frames[i].pixelWidth

    def prefetch(self, job: RenderJob, idx: list[int]):
        def run():
            for i in idx:
                self.proxy(job, i)
        threading.Thread(target=run, daemon=True).start()


class AppState(QObject):
    changed = Signal(str)              # topic
    _main = Signal(object)             # run callable on the main thread

    def __init__(self):
        super().__init__()
        self._main.connect(lambda fn: fn())
        # input
        self.frames: list = []
        self.segments: list = []
        self.segment_index = 0
        self.phase = "empty"            # empty | importing | analyzing | ready | failed
        self.stage = ""
        self.stage_progress = 0.0
        self.analysis_started = time.time()
        self.message = ""
        self.analysis: SequenceAnalysis | None = None
        # settings
        self.composition = Composition()
        self.look = LookSettings()
        self.export = ExportSettings()
        self.selection = FrameSelection()
        self.preset_id: str | None = "lead"
        self.audio = AudioSettings()
        self.watermark = WatermarkSettings()
        self.device = "auto"            # auto | cpu | gpu:<index>
        self.gpu_image = True
        self.agreement_accepted = ""
        # music & watermark
        self.audio_overview: tuple[float, np.ndarray] | None = None
        self.audio_message = ""
        self.preview_audio = True
        self.watermark_qimage: QImage | None = None
        # preview
        self.job: RenderJob | None = None
        self.view_mode = "output"        # output | source
        self.source_tool = "none"        # none | fixEye | pickBird
        self.current_frame = 0
        self.playhead = 0
        self.playing = False
        self.loop_playback = True
        self.preview_image: QImage | None = None
        self.source_image: QImage | None = None
        self.source_detail: tuple[QImage, tuple, int] | None = None   # (image, rect, frame)
        self.source_zoom = 1.0
        self.export_running = False
        self.export_progress = 0.0
        self.export_message = ""
        self.export_path = ""
        self.device_text = ""

        self.engine = PreviewEngine()
        self.cache = ProxyCache()
        self._models: BirdModels | None = None
        self._models_device = None
        self._cancel = CancelFlag()
        self._import_gen = 0
        self._export_cancel = CancelFlag()
        self._crop_edit = None
        self._job_gen = 0
        self._rebuild_timer = QTimer(singleShot=True, interval=60, timeout=self._rebuild_now)
        self._save_timer = QTimer(singleShot=True, interval=400, timeout=self._save_settings_now)
        self._analysis_save_timer = QTimer(singleShot=True, interval=1000, timeout=self._save_analysis_now)
        self._hires_timer = QTimer(singleShot=True, interval=300, timeout=self._render_hires)
        self._play_timer = QTimer(interval=8, timeout=self._tick)
        self._play_start = 0.0
        self._play_start_idx = 0
        self._audio_proc = None
        self._audio_wav_cache: dict = {}
        self._load_settings()
        render.USE_GPU_IMAGE = gpu.setup_opencl(self.gpu_image)

    def on_main(self, fn):
        self._main.emit(fn)

    # ------------------------------------------------------------------ import & analysis

    def import_paths(self, paths: list[str]):
        paths = [p for p in paths if p]
        if not paths:
            return
        self.stop()
        self._cancel.cancel()
        self._import_gen += 1
        gen = self._import_gen
        self.phase = "importing"
        self.analysis = None
        self.job = None
        self.preview_image = self.source_image = None
        self.source_detail = None
        self.changed.emit("phase")

        def work():
            log.info("import %s", paths)
            try:
                fr = F.import_frames(paths)
                segs = F.segments(fr)
            except Exception:
                log.exception("import failed")
                fr, segs = [], []
            log.info("import found %d photos in %d bursts", len(fr), len(segs))

            def done():
                if gen != self._import_gen:
                    return
                self.frames, self.segments = fr, segs
                self.segment_index = 0
                self.current_frame = 0
                if not fr:
                    self.phase = "failed"
                    self.message = "没有找到 JPG / HEIF 图片（也查找了子文件夹）"
                    self.changed.emit("phase")
                    return
                self.segment_index = max(range(len(segs)), key=lambda k: segs[k].count)
                self.changed.emit("frames")
                self.start_analysis()
            self.on_main(done)

        threading.Thread(target=work, daemon=True).start()

    @property
    def current_frames(self) -> list:
        if 0 <= self.segment_index < len(self.segments):
            s = self.segments[self.segment_index]
            fr = [F.SourceFrame(**{**f.__dict__}) for f in self.frames[s.start:s.stop]]
            for i, f in enumerate(fr):
                f.id = i
            return fr
        return list(self.frames)

    def select_segment(self, k: int):
        if k != self.segment_index and 0 <= k < len(self.segments):
            self.segment_index = k
            self.start_analysis()

    def _get_models(self) -> BirdModels:
        if self._models is None or self._models_device != self.device:
            self._models = BirdModels(self.device)
            self._models_device = self.device
            self.device_text = self._models.device_description
            self.on_main(lambda: self.changed.emit("device"))
        return self._models

    def start_analysis(self, hint=None, fresh: bool = False):
        self._cancel.cancel()
        self.stop()
        flag = CancelFlag()
        self._cancel = flag
        fr = self.current_frames
        if not fr:
            return
        fps = self.segments[self.segment_index].fps if self.segments else F.estimate_fps(fr)
        self.phase = "analyzing"
        self.stage, self.stage_progress = "准备", 0.0
        self.analysis_started = time.time()
        self.changed.emit("phase")
        fp = fingerprint(fr)
        keep = (dict(self.analysis.manualEye), set(self.analysis.excluded)) \
            if hint is None and self.analysis is not None and self.analysis.fingerprint == fp else None

        def progress(stage, p):
            if flag.cancelled:
                return
            self.stage, self.stage_progress = stage, p
            self.on_main(lambda: self.changed.emit("progress"))

        def work():
            try:
                if hint is None and not fresh:
                    cached = self.cache.load_analysis(fp)
                    if cached is not None:
                        cached.track = build_track(cached)
                        self.on_main(lambda: self._finish_analysis(cached, flag))
                        return
                self.stage = "加载识别模型"
                self.on_main(lambda: self.changed.emit("progress"))
                models = self._get_models()
                log.info("analysis of %d frames on %s (providers %s)", len(fr), models.device_description, models.detector.providers)
                t0 = time.time()
                a = Analyzer(models).analyze(fr, fps, hint, progress, lambda: flag.cancelled)
                log.info("analysis done in %.1fs: %d/%d birds", time.time() - t0, sum(p.target is not None for p in a.perFrame), a.count)
                if keep:
                    a.manualEye, a.excluded = keep
                    if a.manualEye:
                        a.track = build_track(a)
                self.cache.save_analysis(a)
                self.on_main(lambda: self._finish_analysis(a, flag))
            except Cancelled:
                pass
            except Exception as e:
                log.exception("analysis failed")
                msg = f"分析失败：{e}"

                def fail():
                    if flag is self._cancel and not flag.cancelled:
                        self.phase, self.message = "failed", msg
                        self.changed.emit("phase")
                self.on_main(fail)

        threading.Thread(target=work, daemon=True).start()

    def _finish_analysis(self, a: SequenceAnalysis, flag: CancelFlag):
        if flag is not self._cancel or flag.cancelled:
            return
        self.source_detail = None
        self.current_frame = int(clamp(self.current_frame, 0, max(0, a.count - 1)))
        self.analysis = a
        self.phase = "ready"
        self.selection.trimStart, self.selection.trimEnd = 0, -1
        self.changed.emit("phase")
        self.changed.emit("analysis")
        self.rebuild_job(immediate=True)

    def cancel_analysis(self):
        self._cancel.cancel()
        if self.analysis is None:
            self.frames, self.segments, self.segment_index = [], [], 0
            self.phase = "empty"
        else:
            self.phase = "ready"
        self.changed.emit("phase")

    # ------------------------------------------------------------------ settings → job

    def settings_changed(self, topic: str = "settings"):
        self._save_timer.start()
        self.rebuild_job()
        self.changed.emit(topic)

    def apply_preset(self, p):
        self.preset_id = p.id
        c = p.composition.copy()
        c.edgeFill, c.edgeMargin, c.maxEdgeZoom = self.composition.edgeFill, self.composition.edgeMargin, self.composition.maxEdgeZoom
        self.composition = c
        self.settings_changed()

    def is_preset_active(self, p) -> bool:
        c = p.composition.copy()
        c.edgeFill, c.edgeMargin, c.maxEdgeZoom = self.composition.edgeFill, self.composition.edgeMargin, self.composition.maxEdgeZoom
        return self.preset_id == p.id and c.to_dict() == self.composition.to_dict()

    def rebuild_job(self, immediate: bool = False):
        if immediate:
            self._rebuild_timer.stop()
            self._rebuild_now()
        else:
            self._rebuild_timer.start()

    def _rebuild_now(self):
        a = self.analysis
        if a is None:
            return
        self._job_gen += 1
        gen = self._job_gen
        comp, look, ex, sel = self.composition.copy(), self.look.copy(), self.export.copy(), self.selection.copy()
        a2 = a.copy_edits()

        def work():
            job = RenderJob(a2, comp, look, ex, sel, cache=self.cache)

            def done():
                if gen != self._job_gen or self.analysis is None or self.analysis.fingerprint != a.fingerprint:
                    return
                dur_changed = self.job is None or abs(self.job.duration - job.duration) > 1e-6
                self.job = job
                self.playhead = min(self.playhead, max(0, len(job.output_frames) - 1))
                self.changed.emit("job")
                self.refresh_preview()
                if dur_changed:
                    self._audio_wav_cache.clear()
            self.on_main(done)

        threading.Thread(target=work, daemon=True).start()

    # ------------------------------------------------------------------ edits

    def _edited(self):
        a = self.analysis
        a.track = build_track(a)
        self._analysis_save_timer.start()
        self.changed.emit("analysis")
        self.rebuild_job(immediate=True)

    def set_manual_eye(self, p, frame: int | None = None):
        if self.analysis is None:
            return
        i = self.current_frame if frame is None else frame
        if 0 <= i < self.analysis.count:
            self.analysis.manualEye[i] = (float(p[0]), float(p[1]))
            self._edited()

    def clear_manual_eye(self, all_frames: bool = False):
        if self.analysis is None:
            return
        if all_frames:
            self.analysis.manualEye.clear()
        else:
            self.analysis.manualEye.pop(self.current_frame, None)
        self._edited()

    def toggle_excluded(self):
        a = self.analysis
        if a is None or not 0 <= self.current_frame < a.count:
            return
        a.excluded ^= {self.current_frame}
        self._analysis_save_timer.start()
        self.changed.emit("analysis")
        self.rebuild_job(immediate=True)

    def restore_all_excluded(self):
        if self.analysis is not None:
            self.analysis.excluded.clear()
            self._analysis_save_timer.start()
            self.changed.emit("analysis")
            self.rebuild_job(immediate=True)

    def pick_bird(self, p):
        self.source_tool = "none"
        self.start_analysis(hint=(self.current_frame, (float(p[0]), float(p[1]))))

    def _save_analysis_now(self):
        if self.analysis is not None:
            a = self.analysis.copy_edits()
            threading.Thread(target=lambda: self.cache.save_analysis(a), daemon=True).start()

    def is_predicted(self, i: int) -> bool:
        a = self.analysis
        if a is None or a.track is None or not 0 <= i < a.count:
            return False
        t = a.track
        return (not t.eye_visible[i]) and bool(t.has_data[i]) and i not in a.manualEye

    @property
    def predicted_frames(self) -> list[int]:
        a = self.analysis
        if a is None:
            return []
        job = self.job
        return [i for i in range(a.count) if self.is_predicted(i) and (job is None or (i < len(job.status) and job.status[i] == "ok"))]

    def jump_to_predicted(self, direction: int):
        p = self.predicted_frames
        if not p:
            return
        self.stop()
        if direction > 0:
            target = next((i for i in p if i > self.current_frame), p[0])
        else:
            target = next((i for i in reversed(p) if i < self.current_frame), p[-1])
        self.seek(target)

    def start_fixing_eye(self):
        self.stop()
        self.view_mode = "source"
        self.source_tool = "fixEye"
        if self.source_zoom < 2:
            self.source_zoom = 4.0
        self.changed.emit("view")
        self.refresh_preview()

    # crop editing (drag the crop in the source view)

    def begin_crop_edit(self):
        job = self.job
        if job is None or not job.contains(self.current_frame):
            return
        self.stop()
        xf = job.plan.xforms[self.current_frame]
        W, H = job.output_size
        start_framing = self.composition.framing
        t = self.analysis.track if self.analysis else None
        if t is not None and xf.z > 0:
            shown = min(W, H) / xf.z / t.head_length[self.current_frame]
            if math.isfinite(shown) and shown < start_framing * 0.98:
                start_framing = shown
        self._crop_edit = (self.composition.copy(), start_framing, xf, job.plan.mirrored, float(W), float(H))

    def move_crop(self, d):
        if not self._crop_edit:
            return
        start, _, xf, mirrored, W, H = self._crop_edit
        c, s = math.cos(xf.psi), math.sin(xf.psi)
        do = -xf.z * np.array([c * d[0] - s * d[1], s * d[0] + c * d[1]])
        self.composition.anchorX = clamp(start.anchorX + (-1 if mirrored else 1) * do[0] / W, 0.05, 0.95)
        self.composition.anchorY = clamp(start.anchorY + do[1] / H, 0.05, 0.95)
        self.settings_changed()

    def scale_crop(self, r: float):
        if not self._crop_edit or not math.isfinite(r) or r <= 0:
            return
        self.composition.framing = clamp(self._crop_edit[1] * r, *FRAMING_RANGE)
        self.settings_changed()

    def end_crop_edit(self):
        self._crop_edit = None

    # ------------------------------------------------------------------ preview & playback

    def refresh_preview(self):
        job = self.job
        if job is None:
            return
        i = self.current_frame
        if self.view_mode == "source":
            def run():
                p = self.engine.proxy(job, i)
                if p is not None:
                    q = to_qimage(p)

                    def done():
                        if self.current_frame == i:
                            self.source_image = q
                            self.changed.emit("source")
                    self.on_main(done)
            self.engine.fast.submit(run)
            if self.source_detail and self.source_detail[2] != i:
                self.source_detail = None
            return
        of = job.output_frames[self.playhead] if self.playing and self.playhead < len(job.output_frames) \
            else OutputFrame(i, i, 0.0, 1.0)
        W, H = job.output_size
        scale = min(1.0, 1400 / max(W, H))

        def run():
            img = job.render_output(of, scale=scale, include_watermark=False,
                                    fetch=lambda k: self.engine.proxy_source(job, k))
            if img is not None:
                q = to_qimage(img)

                def done():
                    if self.job is job:
                        self.preview_image = q
                        self.changed.emit("preview")
                self.on_main(done)
        self.engine.fast.submit(run)
        if not self.playing:
            self._hires_timer.start()

    def _render_hires(self):
        job = self.job
        if job is None or self.playing or self.view_mode != "output" or not job.contains(self.current_frame):
            return
        i = self.current_frame
        f = job.analysis.frames[i]
        W, H = job.output_size
        scale = min(1.0, 1800 / max(W, H))
        proxy_scale = job.analysis.proxyLongSide / max(f.pixelWidth, f.pixelHeight)
        needed = min(1.0, job.plan.xforms[i].z * scale * 1.2)
        if needed <= proxy_scale * 1.05:
            return
        s = decode_scale(needed)

        def run():
            src = self.engine.original(job, i, s)
            if src is None:
                return
            img = job.render_output(OutputFrame(i, i, 0.0, 1.0), scale=scale, include_watermark=False, fetch=lambda k: src)
            if img is None:
                return
            q = to_qimage(img)

            def done():
                if self.job is job and self.current_frame == i and not self.playing and self.view_mode == "output":
                    self.preview_image = q
                    self.changed.emit("preview")
            self.on_main(done)
        self.engine.sharp.submit(run)

    def request_source_detail(self, region: tuple, pixels_across: float):
        """Sharp crop of the original for the zoomed source view. region = (x, y, w, h) in source px."""
        job = self.job
        i = self.current_frame
        if job is None or self.view_mode != "source" or self.source_zoom <= 1.01 or not job.contains(i):
            return
        f = job.analysis.frames[i]
        x, y, w, h = region
        x0, y0 = max(0.0, x), max(0.0, y)
        x1, y1 = min(f.pixelWidth, x + w), min(f.pixelHeight, y + h)
        if x1 - x0 < 4 or y1 - y0 < 4:
            return
        needed = min(1.0, pixels_across / (x1 - x0) * 1.1)
        proxy_scale = job.analysis.proxyLongSide / max(f.pixelWidth, f.pixelHeight)
        if needed <= proxy_scale * 1.05:
            return
        s = decode_scale(needed)

        def run():
            src = self.engine.original(job, i, s)
            if src is None:
                return
            img, k = src
            cx0, cy0 = int(x0 * k), int(y0 * k)
            cx1, cy1 = int(math.ceil(x1 * k)), int(math.ceil(y1 * k))
            crop = img[cy0:cy1, cx0:cx1]
            q = to_qimage(crop)
            rect = (cx0 / k, cy0 / k, (cx1 - cx0) / k, (cy1 - cy0) / k)

            def done():
                if self.current_frame == i:
                    self.source_detail = (q, rect, i)
                    self.changed.emit("source")
            self.on_main(done)
        self.engine.sharp.submit(run)

    def seek(self, i: int):
        a = self.analysis
        if a is None or a.count == 0:
            return
        self.current_frame = int(clamp(i, 0, a.count - 1))
        if self.playing and self.job:
            k = next((k for k, of in enumerate(self.job.output_frames) if of.a >= self.current_frame), None)
            if k is not None:
                self.playhead = k
        self.changed.emit("frame")
        self.refresh_preview()

    def step(self, d: int):
        self.stop()
        job = self.job
        if job and self.view_mode == "output" and job.used:
            if d > 0:
                nxt = next((i for i in job.used if i > self.current_frame), None)
                if nxt is not None:
                    return self.seek(nxt)
            else:
                prv = next((i for i in reversed(job.used) if i < self.current_frame), None)
                if prv is not None:
                    return self.seek(prv)
        self.seek(self.current_frame + d)

    def toggle_play(self):
        self.stop() if self.playing else self.play()

    def play(self):
        job = self.job
        if job is None or not job.output_frames:
            return
        if self.view_mode == "source":
            self.view_mode = "output"
            self.changed.emit("view")
        k = next((k for k, of in enumerate(job.output_frames) if of.a >= self.current_frame), None)
        self.playhead = k if k is not None and k < len(job.output_frames) - 1 else 0
        self.playing = True
        self._play_start = time.time()
        self._play_start_idx = self.playhead
        self._start_audio(self.playhead / job.export.outputFPS)
        self._play_timer.start()
        self.changed.emit("playing")

    def stop(self):
        was = self.playing
        self.playing = False
        self._play_timer.stop()
        self._stop_audio()
        if was:
            self.changed.emit("playing")
            self.refresh_preview()

    def _tick(self):
        job = self.job
        if job is None or not self.playing:
            return
        n = len(job.output_frames)
        fps = job.export.outputFPS
        k = self._play_start_idx + int((time.time() - self._play_start) * fps)
        if k >= n:
            if not self.loop_playback:
                self.stop()
                return
            self._play_start, self._play_start_idx, k = time.time(), 0, 0
            self._start_audio(0.0)
        if k != self.playhead or self.preview_image is None:
            self.playhead = k
            self.current_frame = job.output_frames[k].a
            self.engine.prefetch(job, [job.output_frames[(k + j) % n].a for j in range(1, 7)])
            self.changed.emit("frame")
            self.refresh_preview()

    # ------------------------------------------------------------------ music

    def set_audio(self, path: str):
        self.audio.path = path
        self.audio.startOffset = 0.0
        self._audio_changed(path_changed=True)

    def remove_audio(self):
        self.audio.path = ""
        self._audio_changed(path_changed=True)

    def audio_settings_changed(self):
        self._audio_changed(path_changed=False)

    def _audio_changed(self, path_changed: bool):
        self._save_timer.start()
        self._audio_wav_cache.clear()
        if path_changed:
            self.audio_overview = None
            self.audio_message = ""
            self._load_audio_overview()
        self.changed.emit("audio")

    def _load_audio_overview(self):
        path = self.audio.path
        if not path:
            return
        if not os.path.exists(path):
            self.audio_message = f"找不到音乐文件：{os.path.basename(path)}"
            return

        def work():
            try:
                ov = audio_overview(path)
                msg = ""
            except Exception as e:
                ov, msg = None, str(e)

            def done():
                if self.audio.path != path:
                    return
                self.audio_overview, self.audio_message = ov, msg
                if ov and self.audio.startOffset > ov[0]:
                    self.audio.startOffset = 0.0
                self.changed.emit("audio")
            self.on_main(done)
        threading.Thread(target=work, daemon=True).start()

    def toggle_preview_audio(self):
        self.preview_audio = not self.preview_audio
        if not self.preview_audio:
            self._stop_audio()
        elif self.playing and self.job:
            self._start_audio(self.playhead / self.job.export.outputFPS)
        self.changed.emit("audio")

    def _start_audio(self, t: float):
        self._stop_audio()
        job = self.job
        if not (self.preview_audio and self.audio.active and job):
            return
        s, dur = self.audio.copy(), job.duration
        key = (json.dumps(s.to_dict(), sort_keys=True), round(dur, 3), round(t, 2))
        token = object()
        self._audio_token = token

        def work():
            wav = self._audio_wav_cache.get(key) or render_audio_preview(s, dur, t)
            if wav:
                self._audio_wav_cache[key] = wav

            def go():
                if self._audio_token is token and self.playing and wav:
                    self._play_wav(wav)
            self.on_main(go)
        threading.Thread(target=work, daemon=True).start()

    def _play_wav(self, wav: str):
        if IS_WINDOWS:
            import winsound
            winsound.PlaySound(wav, winsound.SND_FILENAME | winsound.SND_ASYNC | winsound.SND_NODEFAULT)
        elif IS_MAC:
            self._audio_proc = subprocess.Popen(["afplay", wav])

    def _stop_audio(self):
        self._audio_token = None
        if IS_WINDOWS:
            try:
                import winsound
                winsound.PlaySound(None, 0)
            except Exception:
                pass
        if self._audio_proc is not None:
            self._audio_proc.terminate()
            self._audio_proc = None

    # ------------------------------------------------------------------ watermark

    def set_watermark_file(self, src: str) -> bool:
        d = data_dir() / "watermarks"
        d.mkdir(parents=True, exist_ok=True)
        dest = d / f"watermark-{uuid.uuid4().hex[:8]}{Path(src).suffix.lower()}"
        try:
            shutil.copyfile(src, dest)
        except OSError as e:
            self.export_message = f"无法读取水印图片：{e}"
            return False
        old = self.watermark.imagePath
        self.watermark.imagePath = str(dest)
        self.watermark.enabled = True
        if old and Path(old).parent == d:
            try:
                os.remove(old)
            except OSError:
                pass
        self.watermark_changed(path_changed=True)
        return True

    def watermark_changed(self, path_changed: bool = False):
        if path_changed:
            self._load_watermark_image()
        self._save_timer.start()
        self.changed.emit("watermark")

    def _load_watermark_image(self):
        self.watermark_qimage = None
        if self.watermark.imagePath and os.path.exists(self.watermark.imagePath):
            img = render.load_watermark(self.watermark.imagePath)
            if img is not None:
                h, w = img.shape[:2]
                self.watermark_qimage = QImage(np.ascontiguousarray(img).data, w, h, w * 4, QImage.Format_ARGB32).copy()

    # ------------------------------------------------------------------ hardware

    def set_device(self, device: str):
        self.device = device
        self._models = None        # reloaded on the next analysis
        self.device_text = ""
        self._save_timer.start()
        self.changed.emit("device")

    def set_gpu_image(self, on: bool):
        self.gpu_image = on
        render.USE_GPU_IMAGE = gpu.setup_opencl(on)
        self._save_timer.start()
        self.changed.emit("device")

    # ------------------------------------------------------------------ export

    def export_to(self, kind: str, path: str):
        a = self.analysis
        if a is None:
            return
        self.stop()
        job = RenderJob(a.copy_edits(), self.composition.copy(), self.look.copy(), self.export.copy(), self.selection.copy(),
                        self.watermark.copy(), self.cache)
        music = self.audio.copy() if kind == "video" and self.audio.active else None
        self.export_running, self.export_progress, self.export_message, self.export_path = True, 0.0, "正在导出…", path
        flag = CancelFlag()
        self._export_cancel = flag
        self.changed.emit("export")

        def progress(p):
            self.export_progress = p
            self.on_main(lambda: self.changed.emit("export"))

        def work():
            ex = VideoExporter()
            t0 = time.time()
            try:
                if kind == "video":
                    ex.export_video(job, path, music, progress, lambda: flag.cancelled)
                elif kind == "images":
                    ex.export_images(job, path, progress, lambda: flag.cancelled)
                else:
                    ex.export_gif(job, path, progress=progress, cancelled=lambda: flag.cancelled)
                enc = f"，编码器 {ex.encoder_used}" if kind == "video" and ex.encoder_used else ""
                msg, prog = f"导出完成（{time.time() - t0:.0f} 秒{enc}）", 1.0
                log.info("export %s done: %s", kind, msg)
            except ExportCancelled:
                msg, prog = "已取消", 0.0
            except Exception as e:
                log.exception("export %s failed", kind)
                msg, prog = str(e), 0.0

            def done():
                self.export_running, self.export_message, self.export_progress = False, msg, prog
                self.changed.emit("export")
            self.on_main(done)
        threading.Thread(target=work, daemon=True).start()

    def cancel_export(self):
        self._export_cancel.cancel()

    # ------------------------------------------------------------------ persistence

    @property
    def settings_path(self) -> Path:
        return data_dir() / "settings.json"

    def save_settings(self):
        self._save_timer.start()

    def _save_settings_now(self):
        d = {"version": 2, "composition": self.composition.to_dict(), "look": self.look.to_dict(),
             "export": self.export.to_dict(), "selection": {**self.selection.to_dict(), "trimStart": 0, "trimEnd": -1},
             "presetID": self.preset_id, "watermark": self.watermark.to_dict(), "audio": self.audio.to_dict(),
             "device": self.device, "gpuImage": self.gpu_image, "agreementAccepted": self.agreement_accepted,
             "inspectorTab": getattr(self, "inspector_tab", 0)}
        try:
            tmp = self.settings_path.with_suffix(".tmp")
            tmp.write_text(json.dumps(d, ensure_ascii=False, indent=1), encoding="utf-8")
            os.replace(tmp, self.settings_path)
        except OSError:
            pass

    def _load_settings(self):
        try:
            d = json.loads(self.settings_path.read_text(encoding="utf-8"))
        except Exception:
            self.composition = PRESETS[1].composition.copy()
            return
        self.composition = Composition.from_dict(d.get("composition"))
        self.look = LookSettings.from_dict(d.get("look"))
        self.export = ExportSettings.from_dict(d.get("export"))
        self.selection = FrameSelection.from_dict(d.get("selection"))
        self.selection.trimStart, self.selection.trimEnd = 0, -1
        self.preset_id = d.get("presetID")
        self.watermark = WatermarkSettings.from_dict(d.get("watermark"))
        if self.watermark.imagePath and not os.path.exists(self.watermark.imagePath):
            self.watermark.imagePath, self.watermark.enabled = "", False
        self._load_watermark_image()
        self.audio = AudioSettings.from_dict(d.get("audio"))
        if self.audio.path and not os.path.exists(self.audio.path):
            self.audio.path = ""
        if self.audio.path:
            self._load_audio_overview()
        self.device = d.get("device", "auto")
        self.gpu_image = bool(d.get("gpuImage", True))
        self.agreement_accepted = d.get("agreementAccepted", "")
        self.inspector_tab = int(d.get("inspectorTab", 0))
