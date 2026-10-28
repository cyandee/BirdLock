"""Experimental local aircraft-part inference; the application does not enable this module yet.

The existing COCO detector supplies the aircraft box. A separate, fixed Grounding DINO query
supplies nose candidates. A body centre is never used as a nose prediction. Four-view agreement
reduces some failures but is not a calibrated probability or a guarantee of correct semantics.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import cv2
import numpy as np

from .paths import resource_dir
from .phasecorr import PhaseCorrelator, extract_exact
from .log import log


def aircraft_threads() -> int:
    logical = os.cpu_count() or 1
    default = 8 if logical >= 16 else min(4, logical)
    try:
        requested = int(os.environ.get("BIRDLOCK_AIRCRAFT_THREADS", str(default)))
    except ValueError:
        requested = default
    return max(1, min(8, logical, requested if requested > 0 else default))


class AircraftCancelled(Exception):
    pass


def model_directory() -> Path:
    for root in (resource_dir() / "aircraft", Path(__file__).resolve().parents[3] / "SharedResources" / "AircraftModels"):
        if (root / "manifest.json").is_file():
            return root
    raise FileNotFoundError("飞机部位模型说明缺失，请重新安装完整测试包。")


def verify_model(directory: Path) -> dict:
    meta = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    name = meta["file"]
    if not isinstance(name, str) or Path(name).name != name or ".." in name or "\\" in name:
        raise ValueError("飞机模型文件名无效。")
    path = directory / name
    if not path.is_file():
        raise FileNotFoundError("飞机部位模型尚未安装；请使用包含该模型的完整测试包。")
    if path.stat().st_size != meta["bytes"]:
        raise ValueError("飞机部位模型校验失败，未运行或替换该文件。")
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != meta["sha256"]:
        raise ValueError("飞机部位模型校验失败，未运行或替换该文件。")
    return meta


@dataclass(frozen=True)
class NoseCandidate:
    rotation: int
    score: float
    x: float
    y: float
    w: float
    h: float


@dataclass(frozen=True)
class NoseObservation:
    x: float
    y: float
    w: float
    h: float
    score: float
    views: int

    @property
    def center(self) -> np.ndarray:
        return np.array([self.x + self.w / 2, self.y + self.h / 2])


@dataclass(frozen=True)
class NoseTrackStep:
    nose: NoseObservation
    registration_quality: float


class NoseImageTracker:
    """Refine a real nose seed using image content, with body motion only as a search hint.

    A rejected step returns None: callers must re-detect or mark the observation missing.
    Group boundaries and model refresh intervals are the sequence caller's responsibility.
    """
    def __init__(self):
        self._correlator = PhaseCorrelator(128)
        self._correlator.set_gaussian_window(20)

    @staticmethod
    def _patch(image, origin, factor):
        if image.ndim == 2:
            return extract_exact(image, *origin, 128, factor)
        # Convert only the sampled region, with identical uint8 BGR->gray rounding.
        x, y = map(int, origin)
        h, w = image.shape[:2]
        x0, y0, x1, y1 = max(0, x), max(0, y), min(w, x+128*factor), min(h, y+128*factor)
        if x1 <= x0 or y1 <= y0:
            return np.full((128, 128), .5, np.float32)
        gray = cv2.cvtColor(image[y0:y1, x0:x1], cv2.COLOR_BGR2GRAY)
        return extract_exact(gray, x-x0, y-y0, 128, factor)

    def step(self, previous: np.ndarray, current: np.ndarray, nose: NoseObservation,
             previous_body, current_body) -> NoseTrackStep | None:
        fields = [nose.x, nose.y, nose.w, nose.h,
                  previous_body.x, previous_body.y, previous_body.w, previous_body.h,
                  current_body.x, current_body.y, current_body.w, current_body.h]
        if not all(math.isfinite(v) for v in fields) or min(nose.w, nose.h, previous_body.w,
                                                           previous_body.h, current_body.w, current_body.h) <= 0:
            return None
        if (previous.ndim not in (2, 3) or current.ndim not in (2, 3)
                or (previous.ndim == 3 and previous.shape[2] != 3)
                or (current.ndim == 3 and current.shape[2] != 3)
                or min(*previous.shape[:2], *current.shape[:2]) <= 0):
            return None
        a_body = np.array([previous_body.x+previous_body.w/2, previous_body.y+previous_body.h/2])
        b_body = np.array([current_body.x+current_body.w/2, current_body.y+current_body.h/2])
        ratio = np.clip(np.array([current_body.w/previous_body.w, current_body.h/previous_body.h]), .5, 2)
        prediction = b_body + (nose.center-a_body)*ratio
        factor = max(1, min(8, round(max(nose.w, nose.h)*3/128)))
        side = 128*factor
        a_height, a_width = previous.shape[:2]
        height, width = current.shape[:2]
        if not (0 <= nose.center[0] < a_width and 0 <= nose.center[1] < a_height):
            return None
        origin_a = np.round(nose.center-side/2).astype(int)
        patch_a = self._patch(previous, origin_a, factor)
        if float(patch_a.var()) < 1e-6:
            return None
        # COCO body boxes can jump between an entire airframe and its wings. Compare a local
        # image-only hypothesis with that coarse body hint, rather than forcing the latter.
        predictions = [nose.center]
        if np.isfinite(prediction).all() and np.linalg.norm(prediction-nose.center) > 1:
            predictions.append(prediction)
        matches = []
        for hint in predictions:
            if not (-side <= hint[0] <= width+side and -side <= hint[1] <= height+side):
                continue
            origin_b = np.round(hint-side/2).astype(int)
            patch_b = self._patch(current, origin_b, factor)
            if float(patch_b.var()) < 1e-6:
                continue
            result = self._correlator.correlate(patch_a, patch_b)
            if result is None:
                continue
            shift, quality = result
            if not math.isfinite(quality) or quality < 25 or not np.isfinite(shift).all() or np.linalg.norm(shift) > 128*.3:
                continue
            point = nose.center+(origin_b-origin_a)+shift*factor
            pad = max(current_body.w, current_body.h)*.22
            if not (0 <= point[0] < width and 0 <= point[1] < height
                    and current_body.x-pad <= point[0] <= current_body.x+current_body.w+pad
                    and current_body.y-pad <= point[1] <= current_body.y+current_body.h+pad):
                continue
            matches.append((quality,point))
        if not matches:
            return None
        matches.sort(key=lambda result: -result[0])
        quality,point = matches[0]
        if len(matches)>1 and np.linalg.norm(point-matches[1][1]) > max(nose.w,nose.h)*.5 and quality < matches[1][0]*1.35:
            return None  # Comparable but conflicting image matches need fresh semantic detection.
        # A translation matcher does not measure part scale; refresh size semantically instead
        # of accumulating noisy body-width ratios into the nose rectangle.
        w, h = nose.w,nose.h
        # Zero views explicitly distinguishes image tracking from a fresh semantic detection.
        tracked = NoseObservation(float(point[0]-w/2), float(point[1]-h/2), float(w), float(h), nose.score, 0)
        return NoseTrackStep(tracked, float(quality))


def choose_consensus(candidates: list[NoseCandidate], body, min_views=2) -> NoseObservation | None:
    """Each view contributes at most once; reject absent agreement rather than invent a point."""
    span = max(body.w, body.h)
    if not math.isfinite(span) or span <= 0:
        return None
    valid = [c for c in candidates if all(math.isfinite(v) for v in (c.x, c.y, c.w, c.h, c.score))
             and c.w > 0 and c.h > 0 and c.score >= 0.25]
    best = None
    for centre in valid:
        views: dict[int, NoseCandidate] = {}
        for c in valid:
            if math.hypot(c.x-centre.x, c.y-centre.y) > span * 0.12:
                continue
            if c.rotation not in views or c.score > views[c.rotation].score:
                views[c.rotation] = c
        group = list(views.values())
        weight = sum(c.score for c in group)
        rank = (len(group), weight)
        if best is None or rank > best[0]:
            best = (rank, group)
    if best is None or best[0][0] < min_views:
        return None
    group = best[1]
    weights = np.array([c.score for c in group])
    x, y, w, h = np.average([[c.x, c.y, c.w, c.h] for c in group], axis=0, weights=weights)
    # Candidate x/y refer to the centre; the persisted observation is an ordinary bounding box.
    return NoseObservation(float(x-w/2), float(y-h/2), float(w), float(h),
                           float(np.mean(weights)), len(group))


class AircraftPartsModel:
    """Lazy CPU session: no model allocation while importing this module or using bird mode.

    All rotations of one request share a lock. Callers must also bound image decoding concurrency;
    the runtime's inference arena can use roughly 2 GB on the tested Mac.
    """
    def __init__(self, directory: Path | None = None):
        self.directory = directory
        self._session = None
        self._meta = None
        self._lock = threading.Lock()

    def _load(self):
        if self._session is not None:
            return
        directory = self.directory or model_directory()
        meta = verify_model(directory)
        # Import only after validation and only when aircraft inference is actually requested.
        import onnxruntime as ort
        options = ort.SessionOptions()
        options.intra_op_num_threads = aircraft_threads()
        options.log_severity_level = 3
        session = ort.InferenceSession(str(directory / meta["file"]), sess_options=options,
                                       providers=["CPUExecutionProvider"])
        self._meta, self._session = meta, session
        log.info("aircraft nose provider=CPU cpu_threads=%d", options.intra_op_num_threads)

    def close(self):
        """Drop the runtime arena after analysis; previews and bird mode must not retain it."""
        with self._lock:
            self._session = None
            self._meta = None

    def detect(self, image: np.ndarray, body, cancelled: Callable[[], bool] = lambda: False,
               progress: Callable[[float], None] | None = None) -> NoseObservation | None:
        with self._lock:
            if cancelled():
                raise AircraftCancelled()
            if image.ndim != 3 or image.shape[2] != 3 or image.dtype != np.uint8:
                raise ValueError("飞机部位检测需要三通道照片。")
            values = (body.x, body.y, body.w, body.h)
            if not all(math.isfinite(v) for v in values) or min(body.w, body.h) <= 0:
                return None
            height, width = image.shape[:2]
            if max(height, width) > 4096:
                raise ValueError("分析照片尺寸超出范围，请重新生成预览后重试。")
            span = max(body.w, body.h)
            pad = span * 0.22
            x0, y0 = max(0, int(body.x-pad)), max(0, int(body.y-pad))
            x1, y1 = min(width, int(body.x+body.w+pad)), min(height, int(body.y+body.h+pad))
            if x1 <= x0 or y1 <= y0:
                return None
            self._load()
            meta = self._meta
            crop = image[y0:y1, x0:x1]
            ch, cw = crop.shape[:2]
            side = max(ch, cw)
            off = np.array([(side-cw)//2, (side-ch)//2])
            padded = np.full((side, side, 3), 127, np.uint8)
            padded[off[1]:off[1]+ch, off[0]:off[0]+cw] = crop
            size = meta["input_size"]
            ids = np.array([meta["token_ids"]], np.int64)
            fixed = {"input_ids": ids, "token_type_ids": np.zeros_like(ids),
                     "attention_mask": np.ones_like(ids), "pixel_mask": np.ones((1, size, size), np.int64)}
            mean = np.array(meta["image_mean"], np.float32)
            std = np.array(meta["image_std"], np.float32)
            candidates = []
            for iteration, degrees in enumerate((0, 90, 180, 270)):
                if cancelled():
                    raise AircraftCancelled()
                matrix = cv2.getRotationMatrix2D((side/2, side/2), degrees, 0.85)
                inverse = cv2.invertAffineTransform(matrix)
                rotated = cv2.warpAffine(padded, matrix, (side, side), borderValue=(127, 127, 127))
                pixels = cv2.cvtColor(cv2.resize(rotated, (size, size)), cv2.COLOR_BGR2RGB).astype(np.float32) / 255
                blob = ((pixels-mean)/std).transpose(2, 0, 1)[None]
                logits, boxes = self._session.run(["logits", "pred_boxes"], dict(fixed, pixel_values=blob))
                if cancelled():
                    raise AircraftCancelled()
                if logits.shape != (1, 900, 256) or boxes.shape != (1, 900, 4):
                    raise ValueError("飞机模型输出维度无效。")
                if not np.isfinite(logits[0, :, meta["nose_token_index"]]).all():
                    raise ValueError("飞机模型输出包含无效数值。")
                scores = 1 / (1 + np.exp(-np.clip(logits[0, :, meta["nose_token_index"]], -40, 40)))
                for index in np.argsort(-scores)[:15]:
                    score = float(scores[index])
                    cx, cy, w, h = boxes[0, index] * side
                    w, h = float(w / .85), float(h / .85)
                    if not all(math.isfinite(v) for v in (score, cx, cy, w, h)):
                        continue
                    if score < .25 or min(w, h) <= 0 or w*h > body.w*body.h*.3 or max(w, h) > span*.6:
                        continue
                    point = inverse[:, :2] @ np.array([cx, cy]) + inverse[:, 2] - off + [x0, y0]
                    if not (0 <= point[0] < width and 0 <= point[1] < height
                            and body.x-pad <= point[0] <= body.x+body.w+pad
                            and body.y-pad <= point[1] <= body.y+body.h+pad):
                        continue
                    if degrees in (90, 270):
                        w, h = h, w
                    candidates.append(NoseCandidate(degrees, score, float(point[0]), float(point[1]), w, h))
                if progress:
                    progress((iteration+1)/4)
            return choose_consensus(candidates, body)
