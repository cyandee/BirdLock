"""Synthetic fixtures and model execution evidence for local Windows acceptance."""
from __future__ import annotations

from collections import Counter
import json
from pathlib import Path
import subprocess
import time
from unittest.mock import patch


def create_media(root: Path, ffmpeg: str | None) -> dict[str, Path]:
    """Create deterministic moving subjects, with no input photos or external assets."""
    import numpy as np
    from PIL import Image, ImageDraw

    root.mkdir()
    media = {}
    rng = np.random.default_rng(20261109)
    y = np.linspace(0, 1, 540)[:, None, None]
    for kind, count, top, bottom in (
        ("birds", 12, (113, 153, 101), (80, 99, 53)),
        ("aircraft", 20, (76, 135, 188), (170, 201, 225)),
    ):
        directory = root / kind
        directory.mkdir()
        background = np.asarray(top) * (1 - y) + np.asarray(bottom) * y
        background = np.clip(background + rng.normal(0, 2, (540, 960, 1)), 0, 255).astype(np.uint8)
        for i in range(count):
            im = Image.fromarray(background)
            d = ImageDraw.Draw(im)
            x, z = i * 3, (i % 7) - 3

            def points(vertices):
                return [(a + x, b + z) for a, b in vertices]

            def ellipse(box, color):
                a, b, c, e = box
                d.ellipse((a+x, b+z, c+x, e+z), fill=color)

            if kind == "birds":
                d.line((130, 418, 841, 390), fill=(74, 49, 38), width=25)
                d.polygon(points([(270, 388), (381, 313), (449, 362), (299, 412)]), fill=(55, 58, 62))
                d.line(points([(440, 348), (438, 410), (467, 402)]), fill=(117, 73, 66), width=7)
                ellipse((349, 229, 595, 386), (151, 156, 161))
                ellipse((355, 264, 539, 356), (90, 98, 110))
                for k in range(7):
                    d.line(points([(378+k*6, 293+k*7), (503+k*2, 288+k*7)]), fill=(111, 121, 132), width=3)
                ellipse((488, 220, 588, 322), (63, 94, 89))
                ellipse((495, 168, 594, 266), (102, 112, 121))
                d.polygon(points([(579, 208), (633, 227), (576, 235)]), fill=(56, 51, 53))
                ellipse((550, 198, 573, 222), (214, 133, 53))
                ellipse((554, 201, 570, 217), (18, 20, 23))
                ellipse((562, 203, 566, 207), (245, 244, 239))
            else:
                d.polygon(points([(247, 242), (218, 157), (244, 153), (320, 244)]), fill=(34, 68, 134))
                d.polygon(points([(432, 249), (355, 191), (389, 187), (551, 247)]), fill=(197, 203, 209))
                d.polygon(points([(229, 249), (310, 238), (684, 226), (741, 243), (756, 260),
                                  (713, 282), (328, 286), (248, 271)]), fill=(237, 240, 242))
                d.line(points([(253, 265), (715, 268)]), fill=(36, 72, 141), width=8)
                d.polygon(points([(657, 235), (705, 234), (731, 246), (670, 245)]), fill=(48, 63, 79))
                for k in range(24):
                    ellipse((334+k*13, 246, 340+k*13, 252), (66, 87, 104))
                d.polygon(points([(508, 261), (566, 270), (404, 365), (358, 359)]), fill=(190, 201, 212))
                ellipse((462, 293, 552, 329), (221, 226, 231))
                ellipse((523, 299, 554, 325), (77, 87, 96))
            im.save(directory / f"{i:04d}.jpg", quality=93)
        media[kind] = directory
        if ffmpeg is None:
            continue
        video = root / f"{kind}.mp4"
        subprocess.run([ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error",
                        "-stream_loop", "1", "-framerate", "15", "-i", str(directory / "%04d.jpg"),
                        "-f", "lavfi", "-i", "sine=frequency=330:sample_rate=48000",
                        "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", str(video)],
                       check=True, timeout=120)
        media[kind + "_video"] = video
    return media


def inference_evidence(device: str, birds: Path, aircraft: Path, output: Path) -> dict:
    """Time uncached app analysis and collect actual ONNX kernel provider events."""
    import cv2
    import numpy as np
    import onnxruntime as ort
    from birdlock.core import frames, gpu, log
    from birdlock.core.aircraft import AircraftPartsModel, model_directory
    from birdlock.core.analysis import Analyzer
    from birdlock.core.models import BirdModels, Detection

    log.setup()
    real_session = ort.InferenceSession
    sessions = {}
    output.mkdir(parents=True, exist_ok=True)

    def profiled_session(path, sess_options, providers):
        # Keep the app's real provider selection and fallback; only enable tracing.
        sess_options.enable_profiling = True
        sess_options.profile_file_prefix = str(output / Path(path).stem)
        session = real_session(path, sess_options=sess_options, providers=providers)
        sessions[Path(path).name] = session, session.get_providers()
        return session

    imported = frames.import_frames([str(birds)])[:12]
    if not imported:
        raise ValueError("No readable benchmark photos")
    with patch.object(ort, "InferenceSession", profiled_session):
        started = time.perf_counter()
        models = BirdModels(device=device)
        load = time.perf_counter() - started
    started = time.perf_counter()
    analysis = Analyzer(models).analyze(imported, frames.estimate_fps(imported))
    analysis_seconds = time.perf_counter() - started
    detector_calls = models.detector.timing_snapshot()
    pose_calls = models.pose.timing_snapshot()
    # Synthetic scenes may have no detector hit. Probe the real pose network separately
    # in that case, without pretending that the analysis found an eye.
    if not pose_calls["calls"]:
        probe = np.full((640, 640, 3), 127, np.uint8)
        models.pose.detect(probe)
    evidence = dict(requested_device=device, requested_providers=gpu.onnx_providers(device),
                    available_providers=ort.get_available_providers(),
                    bird=dict(load_seconds=load, analysis_seconds=analysis_seconds, frames=len(imported),
                              target_frames=sum(p.target is not None for p in analysis.perFrame),
                              description=models.device_description,
                              analysis_detector=detector_calls, analysis_pose=pose_calls, models={}))
    for name, (session, initial) in sessions.items():
        profile = Path(session.end_profiling())
        events = json.loads(profile.read_text(encoding="utf-8"))
        nodes = Counter(e["args"]["provider"] for e in events if e.get("cat") == "Node"
                        and e.get("name", "").endswith("_kernel_time") and e.get("args", {}).get("provider"))
        evidence["bird"]["models"][name] = dict(initial=initial, final=session.get_providers(),
                                                 kernel_events=dict(nodes))
    report = output / "inference.json"
    report.write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8")
    if not (model_directory() / "AircraftParts.onnx").is_file():
        evidence["aircraft_parts_skipped"] = "Aircraft model not installed"
        report.write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8")
        return evidence
    # Bound the aircraft probe to one image and a fixed body ROI. It measures the
    # optional parts model even if the synthetic fuselage is not detected by YOLO.
    selected = frames.import_frames([str(aircraft)])[0]
    image = cv2.imdecode(np.fromfile(selected.path, dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError("Unreadable aircraft benchmark image")
    h, w = image.shape[:2]
    parts = AircraftPartsModel(device=device)
    started = time.perf_counter()
    try:
        observation = parts.detect(image, Detection(w*.15, h*.20, w*.7, h*.6, 1))
        evidence["aircraft_parts"] = dict(seconds=time.perf_counter() - started, observed=observation is not None,
                                           timing=parts._timing.copy(),
                                           provider_list=parts.providers, kernel_events=parts.execution,
                                           description=parts.device_description, fallback=parts.fallback_reason)
    finally:
        parts.close()
    report.write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8")
    return evidence
