"""YOLO detector / pose models via ONNX Runtime (port of Vision/YOLOModel.swift and ModelStore.swift).

Raw Ultralytics output without NMS: [1, 4 + nc + nk*3, anchors], boxes as cx, cy, w, h in input pixels.
"""
from __future__ import annotations

import json
import os
import threading
import time
from dataclasses import dataclass, field

import cv2
import numpy as np

from . import gpu
from .paths import models_dir
from .log import log


def inference_threads() -> int:
    # Keep runtime defaults unless an explicit diagnostic override was requested.
    # A fixed four-thread limit did not improve complete bird analysis in benchmarks.
    try:
        requested = int(os.environ.get("BIRDLOCK_CPU_THREADS", "0"))
    except ValueError:
        requested = 0
    if requested == 0:
        return 0
    return max(1, min(32, os.cpu_count() or 1, requested))


@dataclass
class Keypoint:
    x: float
    y: float
    conf: float


@dataclass
class Detection:
    x: float
    y: float
    w: float
    h: float
    score: float
    keypoints: list[Keypoint] = field(default_factory=list)

    def iou(self, o: "Detection") -> float:
        x0, y0 = max(self.x, o.x), max(self.y, o.y)
        x1, y1 = min(self.x + self.w, o.x + o.w), min(self.y + self.h, o.y + o.h)
        if x1 <= x0 or y1 <= y0:
            return 0.0
        inter = (x1 - x0) * (y1 - y0)
        return inter / (self.w * self.h + o.w * o.h - inter)


@dataclass
class PoseSchema:
    keypoints: list[str]
    inputCropExpand: float = 1.25

    def index(self, part: str) -> int | None:
        return self.keypoints.index(part) if part in self.keypoints else None


CUB15 = PoseSchema(["back", "beak", "belly", "breast", "crown", "forehead", "left_eye", "left_leg", "left_wing", "nape",
                    "right_eye", "right_leg", "right_wing", "tail", "throat"], 1.25)


class YOLOModel:
    def __init__(self, path: str, keypoints: int = 0, device: str = "auto"):
        import onnxruntime as ort
        so = ort.SessionOptions()
        so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        so.intra_op_num_threads = inference_threads()
        providers = gpu.onnx_providers(device)
        if any((p[0] if isinstance(p, tuple) else p) == "DmlExecutionProvider" for p in providers):
            so.enable_mem_pattern = False
            so.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
        try:
            self.session = ort.InferenceSession(path, sess_options=so, providers=providers)
        except Exception:
            log.exception("preferred inference provider failed; falling back to CPU")
            self.session = ort.InferenceSession(path, sess_options=so, providers=["CPUExecutionProvider"])
        inp = self.session.get_inputs()[0]
        self.input_name = inp.name
        self.input_size = int(inp.shape[-1]) if isinstance(inp.shape[-1], int) else 640
        self.output_name = self.session.get_outputs()[0].name
        meta = self.session.get_modelmeta().custom_metadata_map
        names = meta.get("names", "")
        import re
        self.class_names = re.findall(r"\d+:\s*'([^']*)'", names)
        nk = keypoints
        if not nk and "kpt_shape" in meta:
            nums = re.findall(r"\d+", meta["kpt_shape"])
            nk = int(nums[0]) if nums else 0
        self.num_keypoints = nk
        self.num_classes = len(self.class_names) or 1
        self.providers = self.session.get_providers()
        log.info("model %s providers=%s cpu_threads=%s", os.path.basename(path), self.providers,
                 so.intra_op_num_threads or "auto")
        self._lock = threading.Lock()
        self._timing = dict(calls=0, preprocess=0.0, queue=0.0, inference=0.0)

    def timing_snapshot(self) -> dict:
        """Cumulative worker seconds; queue time overlaps other workers' inference."""
        with self._lock:
            return dict(self._timing)

    @property
    def bird_class(self) -> int:
        for i, n in enumerate(self.class_names):
            if n.lower() == "bird":
                return i
        return 14 if self.num_classes == 80 else 0

    @property
    def airplane_class(self) -> int | None:
        for i, name in enumerate(self.class_names):
            if name.lower() == "airplane":
                return i
        return 4 if self.num_classes == 80 else None

    def _letterbox(self, img: np.ndarray, region: tuple[float, float, float, float]):
        """Crop `region` (x, y, w, h; may exceed the image) and fit it into a gray square input."""
        S = self.input_size
        x, y, w, h = region
        x0, y0 = int(round(x)), int(round(y))
        x1, y1 = int(round(x + w)), int(round(y + h))
        H, W = img.shape[:2]
        crop = img[max(0, y0):min(H, y1), max(0, x0):min(W, x1)]
        pt, pl = max(0, -y0), max(0, -x0)
        pb, pr = max(0, y1 - H), max(0, x1 - W)
        if pt or pl or pb or pr:
            crop = cv2.copyMakeBorder(crop, pt, pb, pl, pr, cv2.BORDER_CONSTANT, value=(114, 114, 114))
        cw, ch = x1 - x0, y1 - y0
        r = S / max(cw, ch)
        nw, nh = max(1, int(round(cw * r))), max(1, int(round(ch * r)))
        interp = cv2.INTER_AREA if r < 1 else cv2.INTER_CUBIC
        resized = cv2.resize(crop, (nw, nh), interpolation=interp)
        canvas = np.full((S, S, 3), 114, np.uint8)
        px, py = (S - nw) // 2, (S - nh) // 2
        canvas[py:py + nh, px:px + nw] = resized
        rx, ry = nw / cw, nh / ch
        # model input: RGB, float, NCHW
        blob = cv2.cvtColor(canvas, cv2.COLOR_BGR2RGB).astype(np.float32).transpose(2, 0, 1)[None] / 255.0
        return blob, (x0, y0, px, py, rx, ry)

    def detect(self, img: np.ndarray, crop=None, class_index: int | None = None, score_threshold=0.2,
               iou_threshold=0.5, max_results=20) -> list[Detection]:
        """Detections in `img` pixel coordinates (top-left origin)."""
        region = crop or (0.0, 0.0, float(img.shape[1]), float(img.shape[0]))
        started = time.perf_counter()
        blob, (x0, y0, px, py, rx, ry) = self._letterbox(img, region)
        ready = time.perf_counter()
        # DirectML does not support concurrent Run() calls on one session (crashes): serialize inference.
        with self._lock:
            running = time.perf_counter()
            try:
                out = self.session.run([self.output_name], {self.input_name: blob})[0]
            finally:
                self._timing['calls'] += 1
                self._timing['preprocess'] += ready - started
                self._timing['queue'] += running - ready
                self._timing['inference'] += time.perf_counter() - running
                # ORT can change providers on its first Run(), after construction.
                providers = self.session.get_providers()
                if providers != self.providers:
                    log.warning("model runtime providers changed: %s -> %s", self.providers, providers)
                    self.providers = providers
        a = out[0].astype(np.float32)          # [C, N]
        C = a.shape[0]
        nc = C - 4 - self.num_keypoints * 3
        if nc < 1:
            raise ValueError(f"unexpected model output channels {C}")
        cidx = min(class_index if class_index is not None else self.bird_class, nc - 1)
        scores = a[4 + cidx]
        sel = np.nonzero(scores >= score_threshold)[0]
        dets = []
        for n in sel[np.argsort(-scores[sel])][:300]:
            cx, cy, w, h = a[0, n], a[1, n], a[2, n], a[3, n]
            kps = []
            for k in range(self.num_keypoints):
                base = 4 + nc + 3 * k
                kps.append(Keypoint(float((a[base, n] - px) / rx + x0), float((a[base + 1, n] - py) / ry + y0), float(a[base + 2, n])))
            dets.append(Detection(float((cx - w / 2 - px) / rx + x0), float((cy - h / 2 - py) / ry + y0),
                                  float(w / rx), float(h / ry), float(scores[n]), kps))
        keep: list[Detection] = []
        for d in dets:                         # already sorted by score
            if any(k.iou(d) > iou_threshold for k in keep):
                continue
            keep.append(d)
            if len(keep) >= max_results:
                break
        return keep


class BirdModels:
    """Detector + pose model, created once."""

    def __init__(self, device: str = "auto"):
        d = models_dir()
        self.detector = YOLOModel(str(d / "BirdDetector.onnx"), 0, device)
        try:
            with open(d / "BirdPose.json", encoding="utf-8") as f:
                js = json.load(f)
            self.schema = PoseSchema(js["keypoints"], js.get("inputCropExpand", 1.25))
        except Exception:
            self.schema = CUB15
        self.pose = YOLOModel(str(d / "BirdPose.onnx"), len(self.schema.keypoints), device)
        self.device = device

    @property
    def device_description(self) -> str:
        detector = gpu.describe_device(self.detector.providers, self.device)
        pose = gpu.describe_device(self.pose.providers, self.device)
        return detector if detector == pose else f"识鸟：{detector} · 鸟头：{pose}"

    def device_for_stage(self, stage: str) -> str:
        if stage == "定位鸟头/鸟眼":
            return gpu.describe_device(self.pose.providers, self.device)
        if stage == "识别鸟":
            return gpu.describe_device(self.detector.providers, self.device)
        return "CPU"
