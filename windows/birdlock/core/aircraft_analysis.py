"""Independent aircraft analysis backend used by the experimental subject selector.

The existing COCO detector supplies bodies; the bird pose network is never called here.
Head observations remain explicit and missing heads are never replaced by body centres.
"""
from __future__ import annotations

from dataclasses import replace
import json
import math
from pathlib import Path
from contextlib import contextmanager
import threading
import os
import time

import cv2
import numpy as np

from . import frames as F, solver
from .aircraft import AircraftCancelled, AircraftPartsModel, model_directory
from .aircraft_sequence import analyze_aircraft_noses
from .analysis import (Analyzer, Box, Cancelled, FrameAnalysis, ProxyCache, SequenceAnalysis, Track,
                       _background_stats, build_track, fingerprint, track_targets)
from .models import PoseSchema
from .phasecorr import extract_exact, sharpness
from .util import fill_gaps, gaussian, running_median, unwrap_angles
from .log import log

_work_slot = threading.Lock()


@contextmanager
def _analysis_slot(cancelled, progress):
    notified = False
    while True:
        if cancelled():raise Cancelled()
        if _work_slot.acquire(timeout=.1):break
        if progress and not notified:
            progress("等待上次分析结束",0)
            notified = True
    try:
        if cancelled():raise Cancelled()
        yield
    finally:
        _work_slot.release()


def analysis_identity(directory: Path | None = None) -> str:
    directory = directory or model_directory()
    meta = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    return f"{meta['id']}:{meta['sha256']}:aircraft-sequence-v2"


def build_aircraft_track(a: SequenceAnalysis) -> Track:
    """Solve only actual nose observations/manual corrections. Called separately for each burst.

    Legacy Track.eye is the generic composition anchor here; no eye was detected. Rendering
    explicitly suppresses aircraft eye boxes, and has_data is false on missing nose frames.
    Interpolated camera positions are not exported as new semantic nose observations.
    """
    n = a.count
    noses, points = [None]*n, np.full((n, 2), np.nan)
    lengths, angles = np.full(n, np.nan), np.full(n, np.nan)
    sigma, confidence = np.ones(n), np.zeros(n)
    for i, per in enumerate(a.perFrame):
        raw = per.aircraft
        nose = raw.nose if raw is not None and raw.source in ("detected", "tracked") else None
        if nose is not None:
            fields = (nose.x, nose.y, nose.w, nose.h, nose.score)
            if (not all(math.isfinite(v) for v in fields) or min(nose.w, nose.h) <= 0
                    or not (0 <= nose.center[0] < a.frames[i].pixelWidth and 0 <= nose.center[1] < a.frames[i].pixelHeight)):
                nose = None
        if nose is not None:
            noses[i] = nose
            points[i] = nose.center
            lengths[i] = max(nose.w, nose.h)
            confidence[i] = .6 if raw.source == "detected" else .5
        manual = a.manualEye.get(i)
        if manual is not None and len(manual) == 2 and all(math.isfinite(v) for v in manual):
            if 0 <= manual[0] < a.frames[i].pixelWidth and 0 <= manual[1] < a.frames[i].pixelHeight:
                points[i], confidence[i] = manual, 1
        body = per.target_box
        if np.isfinite(points[i]).all() and body is not None:
            direction = points[i]-body.center
            if np.isfinite(direction).all() and np.linalg.norm(direction) > 1e-6:
                angles[i] = math.atan2(direction[1], direction[0])
    if np.isfinite(lengths).any():
        log_lengths = fill_gaps(gaussian(running_median(np.log(lengths), 4), 3))
        hl = np.exp(log_lengths)
    else:
        hl = np.full(n, 100.)
    angle = fill_gaps(gaussian(running_median(unwrap_angles(angles), 3), 2)) if np.isfinite(angles).any() else np.zeros(n)
    has = np.isfinite(points).all(axis=1)
    for i in range(n):
        sigma[i] = .5 if confidence[i] == 1 else hl[i]*.05+.7
    # Nose coordinates already contain measured image motion; never consume bird/head fallback links.
    position, _, _ = solver.solve(points, sigma, np.full((n, 2), np.nan), np.ones(n))
    return Track(position, position.copy(), hl, angle, [None]*n, np.zeros(n, bool), has, confidence,
                 False, bool(np.median(np.cos(angle)) >= 0) if n else True, float(np.median(hl)) if n else 100.)


class AircraftAnalyzer:
    def __init__(self, models=None, cache: ProxyCache | None = None, parts_directory: Path | None = None,
                 parts_model=None, proxy_long_side=2560, models_factory=None):
        self.models = models
        self.models_factory = models_factory
        self.cache = cache or ProxyCache()
        self.parts_directory = parts_directory or model_directory()
        self.identity = analysis_identity(self.parts_directory)
        self.parts = parts_model if parts_model is not None else AircraftPartsModel(self.parts_directory)
        self.base = Analyzer(None, cache=self.cache, proxy_long_side=max(1,min(4096, proxy_long_side)),
                             workers=min(4, os.cpu_count() or 1))

    def analyze(self, frames, fps, hint=None, progress=None, cancelled=lambda: False, clips=None):
        entered = False
        try:
            with _analysis_slot(cancelled,progress):
                entered = True
                return self._analyze_serial(frames,fps,hint,progress,cancelled,clips)
        finally:
            if not entered:self.parts.close()

    def _analyze_serial(self, frames, fps, hint=None, progress=None, cancelled=lambda: False, clips=None):
        clips = clips or []
        fp = fingerprint(frames, subject="aircraft", model_identity=self.identity)
        cdir, n = self.cache.directory(fp), len(frames)
        per, scales = [FrameAnalysis(i) for i in range(n)], [1.]*n
        detector,models,cls = None,None,None
        def read(i):
            return F.read_file_image(str(cdir / f"p{i:05d}.jpg"))
        def detect(i):
            photo = frames[i]
            proxy = read(i)
            if proxy is None:
                proxy = F.load_max_side(photo, self.base.proxy_long_side)
                if proxy is None:
                    return
                F.write_jpeg(proxy, str(cdir / f"p{i:05d}.jpg"), 90)
            k = photo.pixelWidth/proxy.shape[1]; scales[i] = k
            detections = detector.detect(proxy, class_index=cls, score_threshold=.15)
            per[i].birds = [Box(d.x*k,d.y*k,d.w*k,d.h*k,d.score) for d in detections]
        def background(i):
            proxy, body = read(i), per[i].target_box
            if proxy is None:
                return
            k = scales[i]
            exclude = None if body is None else (body.x/k-body.w/k*.15,body.y/k-body.h/k*.15,body.w/k*1.3,body.h/k*1.3)
            per[i].bgLinear = _background_stats(proxy, exclude)
        try:
            if cancelled():raise Cancelled()
            models = self.models_factory() if self.models_factory is not None else self.models
            if models is None:raise ValueError("缺少飞机整机检测模型。")
            detector = models.detector
            cls = detector.airplane_class
            if cls is None:
                raise ValueError("当前整机检测模型不包含飞机类别。")
            self.base._map(detect, list(range(n)), progress, "识别飞机", cancelled)
            # Factories should create an owned, short-lived detector rather than capture a model.
            # Releasing these references keeps body and nose inference arenas from overlapping.
            models,detector = None,None
            targets = track_targets([p.birds for p in per], hint, clips)
            for i in range(n):per[i].target = targets[i]
            self.base._map(background, list(range(n)), progress, "分析画面", cancelled)
            bodies = [None if p.target_box is None else replace(p.target_box, x=p.target_box.x/scales[i],y=p.target_box.y/scales[i],
                       w=p.target_box.w/scales[i],h=p.target_box.h/scales[i]) for i,p in enumerate(per)]
            if progress:progress("定位/跟踪机头", 0)
            started = time.monotonic()
            observations = analyze_aircraft_noses(bodies,read,clips=clips,model=self.parts,cancelled=cancelled,
                progress=(lambda p: progress("定位/跟踪机头",p)) if progress else None)
            log.info("aircraft nose seconds=%.3f detected=%d tracked=%d missing=%d",time.monotonic()-started,
                     sum(o.source=="detected" for o in observations),sum(o.source=="tracked" for o in observations),
                     sum(o.nose is None for o in observations))
            for i, raw in enumerate(observations):
                nose = raw.nose
                if nose is not None:
                    k = scales[i]
                    nose = replace(nose,x=nose.x*k,y=nose.y*k,w=nose.w*k,h=nose.h*k)
                per[i].aircraft = replace(raw,nose=nose)
            def score(i):
                nose = observations[i].nose
                if nose is None:return
                proxy = read(i)
                if proxy is None:return
                gray = cv2.cvtColor(proxy,cv2.COLOR_BGR2GRAY)
                side = max(16,min(384,round(max(nose.w,nose.h)*1.5)))
                patch = extract_exact(gray,round(nose.center[0])-side//2,round(nose.center[1])-side//2,side,1)
                per[i].sharpness = sharpness(patch)
            self.base._map(score,list(range(n)),progress,"评估画面清晰度",cancelled)
            if cancelled():raise Cancelled()
            analysis = SequenceAnalysis(fp,frames,fps,self.base.proxy_long_side,per,PoseSchema([]),
                clips=clips,groupedDetection=True,subject="aircraft",modelIdentity=self.identity)
            if progress:progress("计算飞机轨迹",0)
            analysis.track = build_track(analysis)
            if progress:progress("计算飞机轨迹",1)
            return analysis
        except AircraftCancelled:
            raise Cancelled() from None
        finally:
            self.parts.close()
