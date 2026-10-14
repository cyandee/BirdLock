"""Burst analysis: detection, tracking, keypoints, sub-pixel registration and the solved track.

Port of Analysis/{AnalysisModel, TargetTracker, TrackBuilder, Analyzer}.swift and IO/ProxyCache.swift.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import cv2
import numpy as np

from . import frames as F
from . import solver
from .head import EYE, HeadObservation, HeadTemplate
from .models import BirdModels, PoseSchema
from .paths import cache_dir
from .phasecorr import PhaseCorrelator, extract_exact, sharpness
from .util import clamp, fill_gaps, gaussian, median, running_median, unwrap_angles

ANALYSIS_VERSION = 3


class Cancelled(Exception):
    pass


# ---------------------------------------------------------------------------------------------- data model


@dataclass
class Box:
    x: float
    y: float
    w: float
    h: float
    score: float

    @property
    def center(self) -> np.ndarray:
        return np.array([self.x + self.w / 2, self.y + self.h / 2])

    @property
    def diag(self) -> float:
        return math.hypot(self.w, self.h)


@dataclass
class FrameAnalysis:
    index: int
    birds: list = field(default_factory=list)          # [Box]
    target: int | None = None
    keypoints: list = field(default_factory=list)      # [(x, y, conf)]
    poseScore: float = 0.0
    head: HeadObservation = field(default_factory=HeadObservation.empty)
    bgLinear: list = field(default_factory=lambda: [0.0, 0.0, 0.0])   # mean linear RGB of the background
    sharpness: float | None = None
    link: dict | None = None                           # {"delta": [dx, dy], "quality": q, "patchScale": s}

    @property
    def target_box(self) -> Box | None:
        if self.target is None or self.target >= len(self.birds):
            return None
        return self.birds[self.target]

    def to_dict(self):
        return {"index": self.index, "birds": [b.__dict__ for b in self.birds], "target": self.target,
                "keypoints": [list(k) for k in self.keypoints], "poseScore": self.poseScore, "head": self.head.to_dict(),
                "bgLinear": self.bgLinear, "sharpness": self.sharpness, "link": self.link}

    @staticmethod
    def from_dict(d):
        return FrameAnalysis(d["index"], [Box(**b) for b in d["birds"]], d["target"], [tuple(k) for k in d["keypoints"]],
                             d["poseScore"], HeadObservation.from_dict(d["head"]), d["bgLinear"], d["sharpness"], d["link"])


@dataclass
class Track:
    eye: np.ndarray            # (n, 2)
    head_center: np.ndarray    # (n, 2)
    head_length: np.ndarray    # (n,)
    angle: np.ndarray          # (n,) head direction, radians, unwrapped
    measured_eye: list         # [(x, y) | None]
    eye_visible: np.ndarray    # (n,) bool
    has_data: np.ndarray       # (n,) bool
    confidence: np.ndarray     # (n,)
    reflect_dominant: bool
    facing_right: bool
    median_head_length: float

    @property
    def count(self) -> int:
        return len(self.head_length)


@dataclass
class SequenceAnalysis:
    fingerprint: str
    frames: list               # [SourceFrame]
    fps: float
    proxyLongSide: int
    perFrame: list             # [FrameAnalysis]
    poseSchema: PoseSchema
    manualEye: dict = field(default_factory=dict)      # {frame: (x, y)}
    excluded: set = field(default_factory=set)
    track: Track | None = None

    @property
    def count(self) -> int:
        return len(self.frames)

    def to_dict(self):
        return {"version": ANALYSIS_VERSION, "fingerprint": self.fingerprint, "frames": [f.to_dict() for f in self.frames],
                "fps": self.fps, "proxyLongSide": self.proxyLongSide, "perFrame": [p.to_dict() for p in self.perFrame],
                "poseSchema": {"keypoints": self.poseSchema.keypoints, "inputCropExpand": self.poseSchema.inputCropExpand},
                "manualEye": {str(k): list(v) for k, v in self.manualEye.items()}, "excluded": sorted(self.excluded)}

    @staticmethod
    def from_dict(d) -> "SequenceAnalysis":
        a = SequenceAnalysis(d["fingerprint"], [F.SourceFrame.from_dict(f) for f in d["frames"]], d["fps"], d["proxyLongSide"],
                             [FrameAnalysis.from_dict(p) for p in d["perFrame"]],
                             PoseSchema(d["poseSchema"]["keypoints"], d["poseSchema"].get("inputCropExpand", 1.25)),
                             {int(k): tuple(v) for k, v in d.get("manualEye", {}).items()}, set(d.get("excluded", [])))
        return a

    def copy_edits(self) -> "SequenceAnalysis":
        """Shallow copy with independent user edits (manual eyes, exclusions)."""
        b = SequenceAnalysis(self.fingerprint, self.frames, self.fps, self.proxyLongSide, self.perFrame, self.poseSchema,
                             dict(self.manualEye), set(self.excluded), self.track)
        return b


def fingerprint(frames: list) -> str:
    h = hashlib.sha256()
    for f in frames:
        h.update(f"{f.path}|{f.fileSize}|{f.modified}\n".encode())
    return h.hexdigest()[:24]


# ---------------------------------------------------------------------------------------------- cache


class ProxyCache:
    def __init__(self, root: Path | None = None):
        self.root = root or cache_dir()

    def directory(self, fp: str) -> Path:
        d = self.root / fp
        d.mkdir(parents=True, exist_ok=True)
        return d

    def proxy_path(self, fp: str, i: int) -> Path:
        return self.directory(fp) / f"p{i:05d}.jpg"

    def load_proxy(self, fp: str, i: int) -> np.ndarray | None:
        p = self.proxy_path(fp, i)
        return F.read_file_image(str(p)) if p.exists() else None

    def save_analysis(self, a: SequenceAnalysis):
        p = self.directory(a.fingerprint) / "analysis.json"
        tmp = p.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(a.to_dict(), f)
        os.replace(tmp, p)

    def load_analysis(self, fp: str) -> SequenceAnalysis | None:
        p = self.root / fp / "analysis.json"
        try:
            with open(p, encoding="utf-8") as f:
                d = json.load(f)
            if d.get("version") != ANALYSIS_VERSION:
                return None
            a = SequenceAnalysis.from_dict(d)
        except Exception:
            return None
        if any(not self.proxy_path(fp, i).exists() for i in range(a.count)):
            return None
        return a

    def total_size(self) -> int:
        return sum(f.stat().st_size for f in self.root.rglob("*") if f.is_file())

    def clear(self):
        import shutil
        shutil.rmtree(self.root, ignore_errors=True)
        self.root.mkdir(parents=True, exist_ok=True)


# ---------------------------------------------------------------------------------------------- target tracking


def track_targets(birds: list[list[Box]], hint: tuple[int, tuple[float, float]] | None = None) -> list[int | None]:
    """Pick one bird per frame and keep its identity through the sequence."""
    n = len(birds)
    out: list[int | None] = [None] * n
    if n == 0:
        return out
    seed_f = seed_i = -1
    if hint is not None and hint[0] < n and birds[hint[0]]:
        seed_f = hint[0]
        pt = np.array(hint[1])
        seed_i = min(range(len(birds[seed_f])), key=lambda j: float(np.linalg.norm(birds[seed_f][j].center - pt)))
    else:
        best = -1.0
        for f in range(n):
            for i, b in enumerate(birds[f]):
                s = b.score * math.sqrt(b.diag)
                if s > best:
                    best, seed_f, seed_i = s, f, i
    if seed_f < 0:
        return out
    out[seed_f] = seed_i
    for step in (1, -1):
        last = birds[seed_f][seed_i]
        vel = np.zeros(2)
        missed = 0
        f = seed_f + step
        while 0 <= f < n:
            pred = last.center + vel * (missed + 1)
            gate = last.diag * (0.8 + 0.25 * missed)
            best_i, best_c = None, math.inf
            for i, b in enumerate(birds[f]):
                d = float(np.linalg.norm(b.center - pred))
                if d >= gate:
                    continue
                area = math.log(max(1e-6, (b.w * b.h) / max(1e-6, last.w * last.h)))
                c = d / last.diag + 0.35 * abs(area) - 0.2 * b.score
                if c < best_c:
                    best_c, best_i = c, i
            if best_i is not None:
                b = birds[f][best_i]
                v = (b.center - last.center) / (missed + 1)
                vel = vel * 0.5 + v * 0.5 if missed == 0 else v
                last = b
                missed = 0
                out[f] = best_i
            else:
                missed += 1
                if missed > 20:
                    vel = np.zeros(2)
            f += step
    return out


# ---------------------------------------------------------------------------------------------- track builder


def build_track(a: SequenceAnalysis, eye_sigma_hl=0.05, predicted_eye_sigma_hl=0.12, center_sigma_hl=0.06,
                link_min_quality=12.0, link_sigma_patch_px=0.05, use_registration=True) -> Track:
    """Raw per-frame analysis + user edits -> solved, smooth-but-faithful track."""
    n = a.count
    schema = a.poseSchema
    li, ri = schema.index("left_eye"), schema.index("right_eye")
    obs = [p.head for p in a.perFrame]
    if li is not None and ri is not None:
        diff = np.array([p.keypoints[li][2] - p.keypoints[ri][2] if len(p.keypoints) > max(li, ri) else np.nan
                         for p in a.perFrame])
        sm = gaussian(running_median(diff, 7), 6)
        fin = diff[np.isfinite(diff)]
        global_left = fin.sum() >= 0 if fin.size else True
        for i in range(n):
            if a.perFrame[i].keypoints:
                left = sm[i] >= 0 if math.isfinite(sm[i]) else global_left
                obs[i] = HeadObservation.from_keypoints(a.perFrame[i].keypoints, schema, 0.35,
                                                        "left_eye" if left else "right_eye")
    template = HeadTemplate.estimate(obs)

    refl = prop = 0
    if template is not None:
        for ob in obs:
            if ob.valid_count >= 3:
                r = template.fit(ob)
                if r is not None:
                    if r[0].reflect:
                        refl += 1
                    else:
                        prop += 1
    reflect_dominant = refl > prop
    sims = [None] * n
    if template is not None:
        for i in range(n):
            r = template.fit(obs[i], reflect_dominant)
            if r is not None and r[1] < 0.6:
                sims[i] = r[0]
    t_hl = template.head_length if template is not None else 2.0

    # head length (robust)
    hl_raw = np.array([s.s * t_hl if s is not None else np.nan for s in sims])
    ratios = [hl_raw[i] / a.perFrame[i].target_box.diag for i in range(n)
              if math.isfinite(hl_raw[i]) and a.perFrame[i].target_box is not None]
    ratio = median(ratios) or 0.12
    for i in range(n):
        if not math.isfinite(hl_raw[i]) and a.perFrame[i].target_box is not None:
            hl_raw[i] = a.perFrame[i].target_box.diag * ratio
    log_hl = np.where(np.isfinite(hl_raw) & (hl_raw > 0), np.log(np.where(hl_raw > 0, hl_raw, 1)), np.nan)
    log_hl = fill_gaps(gaussian(running_median(log_hl, 4), 3))
    hl = np.where(np.isfinite(log_hl), np.exp(log_hl), 100.0)
    median_hl = median(hl) or 100.0

    # head angle
    ang = np.array([s.theta if s is not None else np.nan for s in sims])
    ang = fill_gaps(gaussian(running_median(unwrap_angles(ang), 3), 2))
    facing_right = (median(np.cos(ang)) or 1) >= 0

    # absolute measurements
    eye_m = np.full((n, 2), np.nan); eye_s = np.ones(n)
    ctr_m = np.full((n, 2), np.nan); ctr_s = np.ones(n)
    measured = [None] * n
    visible = np.zeros(n, bool)
    t_eye = template[EYE] if template is not None else None
    for i in range(n):
        h = hl[i]
        pred_eye = sims[i].apply(t_eye) if sims[i] is not None and t_eye is not None else None
        pred_ctr = sims[i].apply(template.head_center) if sims[i] is not None else None
        e = obs[i][EYE]
        if e is not None:
            measured[i] = e
            if pred_eye is None or float(np.linalg.norm(pred_eye - np.array(e))) <= 0.35 * h:
                visible[i] = True
        man = a.manualEye.get(i)
        if man is not None:
            eye_m[i] = man; eye_s[i] = 0.5
            off = pred_ctr - pred_eye if pred_ctr is not None and pred_eye is not None else np.zeros(2)
            ctr_m[i] = np.array(man) + off; ctr_s[i] = 1.0 if pred_ctr is not None else 0.3 * h
            continue
        box = a.perFrame[i].target_box
        if visible[i]:
            eye_m[i] = e; eye_s[i] = eye_sigma_hl * h + 0.7
        elif pred_eye is not None:
            eye_m[i] = pred_eye; eye_s[i] = predicted_eye_sigma_hl * h + 1.5
        elif box is not None:
            eye_m[i] = box.center; eye_s[i] = 1.5 * h
        if pred_ctr is not None:
            ctr_m[i] = pred_ctr; ctr_s[i] = center_sigma_hl * h + 0.7
        elif box is not None:
            ctr_m[i] = box.center; ctr_s[i] = 1.5 * h

    # registration links
    link_d = np.full((n, 2), np.nan); link_s = np.ones(n)
    if use_registration:
        for i in range(1, n):
            lk = a.perFrame[i].link
            if lk and lk["quality"] >= link_min_quality:
                link_d[i] = lk["delta"]
                link_s[i] = lk["patchScale"] * (link_sigma_patch_px + 12.0 / lk["quality"])
    eye_pos, eye_in, _ = solver.solve(eye_m, eye_s, link_d, link_s)
    ctr_pos, _, _ = solver.solve(ctr_m, ctr_s, link_d, link_s)

    # data coverage: within 8 frames of a real observation
    good = np.isfinite(eye_m).all(1) & (eye_s < hl)
    has = np.zeros(n, bool)
    last = -1000
    for i in range(n):
        if good[i]:
            last = i
        has[i] = i - last <= 8
    last = 10 ** 9
    for i in range(n - 1, -1, -1):
        if good[i]:
            last = i
        has[i] = has[i] or last - i <= 8

    conf = np.zeros(n)
    for i in range(n):
        if i in a.manualEye:
            conf[i] = 1
        elif visible[i]:
            conf[i] = 0.9
        elif sims[i] is not None:
            conf[i] = 0.6
        elif a.perFrame[i].target_box is not None:
            conf[i] = 0.25
        if not eye_in[i]:
            conf[i] *= 0.5
    return Track(eye_pos, ctr_pos, hl, ang, measured, visible, has, conf, reflect_dominant, bool(facing_right), float(median_hl))


# ---------------------------------------------------------------------------------------------- analyzer

STAGES = ["识别鸟", "定位鸟头/鸟眼", "亚像素配准", "计算轨迹"]


def _background_stats(img: np.ndarray, exclude: tuple | None) -> list[float]:
    """Mean linear RGB of a heavily downsampled image, excluding `exclude` (x, y, w, h in img px)."""
    W = 96
    H = max(1, int(round(96 * img.shape[0] / img.shape[1])))
    small = cv2.resize(img, (W, H), interpolation=cv2.INTER_AREA)
    lut = np.array([c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in np.arange(256) / 255.0])
    lin = lut[small]                      # BGR
    mask = np.ones((H, W), bool)
    if exclude is not None:
        sx, sy = W / img.shape[1], H / img.shape[0]
        x, y, w, h = exclude
        xs = (np.arange(W) + 0.5) / sx
        ys = (np.arange(H) + 0.5) / sy
        inside = ((ys[:, None] >= y) & (ys[:, None] < y + h)) & ((xs[None, :] >= x) & (xs[None, :] < x + w))
        mask &= ~inside
    if not mask.any():
        return [0.0, 0.0, 0.0]
    m = lin[mask].mean(0)
    return [float(m[2]), float(m[1]), float(m[0])]   # RGB


class Analyzer:
    def __init__(self, models: BirdModels, cache: ProxyCache | None = None, proxy_long_side=2560, detection_threshold=0.15,
                 keypoint_min_conf=0.35, patch_size=128, patch_head_lengths=3.0, workers: int | None = None):
        self.models = models
        self.cache = cache or ProxyCache()
        self.proxy_long_side = proxy_long_side
        self.detection_threshold = detection_threshold
        self.keypoint_min_conf = keypoint_min_conf
        self.patch_size = patch_size
        self.patch_head_lengths = patch_head_lengths
        self.workers = workers or max(2, min(12, (os.cpu_count() or 4) - 1))

    def _map(self, fn, items, progress, stage, cancelled):
        """Run fn over items on a thread pool (decoding and inference release the GIL), in order."""
        n = len(items)
        done = 0
        lock = threading.Lock()
        results = [None] * n

        def run(i):
            nonlocal done
            if cancelled():
                return
            results[i] = fn(items[i])
            with lock:
                done += 1
                d = done
            if progress:
                progress(stage, d / n)

        with ThreadPoolExecutor(max_workers=self.workers) as ex:
            list(ex.map(run, range(n)))
        if cancelled():
            raise Cancelled()
        return results

    def analyze(self, frames: list, fps: float, hint=None, progress: Callable | None = None,
                cancelled: Callable[[], bool] = lambda: False) -> SequenceAnalysis:
        n = len(frames)
        fp = fingerprint(frames)
        cdir = self.cache.directory(fp)
        det, pose, schema = self.models.detector, self.models.pose, self.models.schema
        per = [FrameAnalysis(i) for i in range(n)]

        # ---- Pass 1: proxies + detection
        def pass1(i):
            f = frames[i]
            pp = cdir / f"p{i:05d}.jpg"
            proxy = F.read_file_image(str(pp)) if pp.exists() else None
            if proxy is None:
                proxy = F.load_max_side(f, self.proxy_long_side)
                if proxy is None:
                    return
                F.write_jpeg(proxy, str(pp), 90)
            k = f.pixelWidth / proxy.shape[1]
            dets = det.detect(proxy, score_threshold=self.detection_threshold)
            per[i].birds = [Box(d.x * k, d.y * k, d.w * k, d.h * k, d.score) for d in dets]

        if progress:
            progress(STAGES[0], 0.0)
        self._map(pass1, list(range(n)), progress, STAGES[0], cancelled)

        targets = track_targets([p.birds for p in per], hint)
        for i in range(n):
            per[i].target = targets[i]

        # ---- Pass 1b: keypoints on the tracked bird + background statistics
        def pass1b(i):
            f = frames[i]
            proxy = F.read_file_image(str(cdir / f"p{i:05d}.jpg"))
            if proxy is None:
                return
            k = f.pixelWidth / proxy.shape[1]
            b = per[i].target_box
            excl = None
            if b is not None:
                excl = (b.x / k - b.w / k * 0.15, b.y / k - b.h / k * 0.15, b.w / k * 1.3, b.h / k * 1.3)
            per[i].bgLinear = _background_stats(proxy, excl)
            kps, ps = [], 0.0
            if b is not None:
                side = max(b.w, b.h) * (schema.inputCropExpand or 1.25)
                crop = (b.center[0] - side / 2, b.center[1] - side / 2, side, side)
                long_side = max(f.pixelWidth, f.pixelHeight)
                need_long = long_side * pose.input_size * 1.3 / side
                img, kk = proxy, k
                if need_long > max(proxy.shape[:2]) * 1.05:
                    target = int(min(long_side, need_long))
                    hi = F.load_max_side(f, target)
                    if hi is not None:
                        img, kk = hi, f.pixelWidth / hi.shape[1]
                c = (crop[0] / kk, crop[1] / kk, crop[2] / kk, crop[3] / kk)
                try:
                    ds = pose.detect(img, crop=c, class_index=0, score_threshold=0.1)
                except Exception:
                    ds = []
                if ds:
                    from .models import Detection
                    tb = Detection(b.x / kk, b.y / kk, b.w / kk, b.h / kk, 1.0)
                    best = max(ds, key=lambda d: d.iou(tb) + 0.3 * d.score)
                    kps = [(kp.x * kk, kp.y * kk, kp.conf) for kp in best.keypoints]
                    ps = best.score
            per[i].keypoints = kps
            per[i].poseScore = ps
            per[i].head = HeadObservation.from_keypoints(kps, schema, self.keypoint_min_conf)

        self._map(pass1b, list(range(n)), progress, STAGES[1], cancelled)

        a = SequenceAnalysis(fp, frames, fps, self.proxy_long_side, per, schema)
        initial = build_track(a)
        a.track = initial

        # ---- Pass 2: head patches (exact, resampling-free), sharpness, registration
        N = self.patch_size
        med_hl = initial.median_head_length
        g = 1.0
        for cand in (0.5, 0.25):
            if med_hl * cand >= 90:
                g = cand
        D = max(1, int(round(med_hl * g * self.patch_head_lengths / N)))
        patches = [None] * n
        rects = [None] * n

        def pass2(i):
            if not initial.has_data[i]:
                return
            f = frames[i]
            img = F.load_image(f, g, gray=True)
            if img is None:
                return
            kk = f.pixelWidth / img.shape[1]
            side = N * D
            hc = initial.head_center[i]
            x0 = int(round(hc[0] / kk - side / 2))
            y0 = int(round(hc[1] / kk - side / 2))
            patches[i] = extract_exact(img, x0, y0, N, D)
            rects[i] = (x0 * kk, y0 * kk, side * kk, side * kk)
            hlp = initial.head_length[i] / kk
            ss = int(clamp(hlp * 1.5, 16, 384))
            sp = extract_exact(img, int(hc[0] / kk) - ss // 2, int(hc[1] / kk) - ss // 2, ss, 1)
            per[i].sharpness = sharpness(sp)

        self._map(pass2, list(range(n)), (lambda s, p: progress(s, p * 0.9)) if progress else None, STAGES[2], cancelled)

        pc = PhaseCorrelator(N)
        pc.set_gaussian_window(clamp(0.6 * med_hl * g / D, 8, N / 4))
        for i in range(1, n):
            pa, pb = patches[i - 1], patches[i]
            if pa is None or pb is None:
                continue
            r = pc.correlate(pa, pb)
            if r is None:
                continue
            shift, q = r
            ra, rb = rects[i - 1], rects[i]
            scale = 0.5 * (ra[2] / N + rb[2] / N)
            ca = np.array([ra[0] + ra[2] / 2, ra[1] + ra[3] / 2])
            cb = np.array([rb[0] + rb[2] / 2, rb[1] + rb[3] / 2])
            delta = (cb - ca) + shift * scale
            per[i].link = {"delta": [float(delta[0]), float(delta[1])], "quality": float(q), "patchScale": float(scale)}
            if cancelled():
                raise Cancelled()
        if progress:
            progress(STAGES[2], 1.0)
            progress(STAGES[3], 0.5)
        a.track = build_track(a)
        if progress:
            progress(STAGES[3], 1.0)
        return a
