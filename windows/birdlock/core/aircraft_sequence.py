"""Bounded aircraft nose analysis used by the experimental aircraft mode.

All boxes and returned observations use the pixel coordinates of load_image's proxies. Each
burst starts from its own body detection; only measured image motion can propagate a nose.
Semantic refresh failures leave missing observations rather than extending an old prediction.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, asdict
from typing import Callable

import cv2
import numpy as np

from .aircraft import AircraftCancelled, AircraftPartsModel, NoseImageTracker, NoseObservation


@dataclass(frozen=True)
class AircraftFrameObservation:
    nose: NoseObservation | None = None
    source: str = "missing"
    registration_quality: float | None = None

    def to_dict(self):
        return asdict(self)

    @staticmethod
    def from_dict(data):
        nose = None if data.get("nose") is None else NoseObservation(**data["nose"])
        source = data.get("source", "missing")
        if source not in ("missing", "detected", "tracked"):
            raise ValueError("无效的飞机定位来源。")
        return AircraftFrameObservation(nose, source, data.get("registration_quality"))


def _valid_body(body) -> bool:
    return body is not None and all(math.isfinite(v) for v in (body.x, body.y, body.w, body.h, body.score)) \
        and min(body.w, body.h) > 0


def _clip_ranges(count: int, clips) -> list[range]:
    if not clips:
        return [range(count)] if count else []
    ranges, cursor = [], 0
    for clip in clips:
        start, length = clip["start"], clip["count"]
        if not isinstance(start, int) or not isinstance(length, int) or start != cursor or length <= 0:
            raise ValueError("飞机片段范围必须连续、不重叠。")
        cursor += length
        if cursor > count:
            raise ValueError("飞机片段范围超过照片数量。")
        ranges.append(range(start, cursor))
    if cursor != count:
        raise ValueError("飞机片段范围必须覆盖所有照片。")
    return ranges


def analyze_aircraft_noses(bodies: list, load_image: Callable[[int], np.ndarray | None], *, clips=None,
                           model: AircraftPartsModel | None = None, refresh_interval: int = 15,
                           retry_interval: int = 5, cancelled: Callable[[], bool] = lambda: False,
                           progress: Callable[[float], None] | None = None) -> list[AircraftFrameObservation]:
    """Initialize per burst, track in both directions, re-detect periodically or after failure.

    Decode at most a seed and two adjacent proxies at a time; use one serial model session.
    Model refresh is deliberately bounded by frame count rather than claiming the body's
    position alone proves which end is the nose. A model created here is released even when
    decoding/inference fails or the user cancels. An injected model remains its owner's resource.
    """
    if refresh_interval < 1 or retry_interval < 1:
        raise ValueError("飞机重检间隔必须大于零。")
    count = len(bodies)
    ranges = _clip_ranges(count, clips)
    result = [AircraftFrameObservation() for _ in bodies]
    completed = 0
    owned_model = model is None

    def check_cancelled():
        if cancelled():
            raise AircraftCancelled()

    def report(fraction=0):
        if progress:
            progress(min(1.0, (completed+fraction)/max(1, count)))

    def read(index):
        check_cancelled()
        image = load_image(index)
        check_cancelled()
        if image is None:
            return None
        if image.ndim != 3 or image.shape[2] != 3 or image.dtype != np.uint8:
            raise ValueError("飞机跟踪需要三通道代理照片。")
        return image

    def detect(index, image):
        nonlocal model
        check_cancelled()
        if model is None:
            model = AircraftPartsModel()
        nose = model.detect(image, bodies[index], cancelled=cancelled, progress=lambda f: report(f*.9))
        check_cancelled()
        if nose is not None:
            result[index] = AircraftFrameObservation(nose, "detected")
        return nose

    try:
        check_cancelled()
        for indices in ranges:
            valid = [i for i in indices if _valid_body(bodies[i])]
            if not valid:
                completed += len(indices)
                report()
                continue
            seed = max(valid, key=lambda i: bodies[i].score*math.sqrt(bodies[i].w*bodies[i].h))
            seed_image = read(seed)
            seed_nose = detect(seed, seed_image) if seed_image is not None else None
            completed += 1
            report()
            for step in (1, -1):
                tracker = NoseImageTracker()
                previous_index, previous_image, previous_nose = seed, seed_image, seed_nose
                since_detection = 0
                retry_after = retry_interval if seed_nose is None else 0
                index = seed+step
                while index in indices:
                    check_cancelled()
                    image, nose = None, None
                    retry_after = max(0, retry_after-1)
                    if _valid_body(bodies[index]) and (previous_nose is not None or retry_after == 0):
                        image = read(index)
                        if image is not None:
                            if previous_nose is not None and since_detection+1 < refresh_interval:
                                tracked = tracker.step(previous_image, image, previous_nose,
                                                       bodies[previous_index], bodies[index])
                                if tracked is not None:
                                    nose = tracked.nose
                                    result[index] = AircraftFrameObservation(nose, "tracked", tracked.registration_quality)
                            if nose is None and (previous_nose is not None or retry_after == 0):
                                nose = detect(index, image)
                                since_detection = -1
                                retry_after = retry_interval if nose is None else 0
                    previous_index, previous_image, previous_nose = index, image, nose
                    since_detection += 1
                    completed += 1
                    report()
                    index += step
        check_cancelled()
        report()
        return result
    finally:
        if owned_model and model is not None:
            model.close()
