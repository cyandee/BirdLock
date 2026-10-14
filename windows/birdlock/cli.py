"""Command line: analyse / export / self-test (also used by CI on Windows).

  python -m birdlock.cli selftest
  python -m birdlock.cli analyze <folder>
  python -m birdlock.cli export <folder> --out out.mp4 [--preset lead] [--aspect 16:9] [--short 1440] [--framing 40]
                                [--edge shift|zoom|blur|black] [--focus] [--audio music.m4a] [--watermark sig.png] [--proxy]
  python -m birdlock.cli devices
"""
from __future__ import annotations

import argparse
import math
import sys
import time

import numpy as np


def _analysis(folder: str, fresh: bool = False):
    from .core import frames as F
    from .core.analysis import Analyzer, ProxyCache, build_track, fingerprint
    from .core.models import BirdModels
    fr = F.import_frames([folder])
    if not fr:
        sys.exit(f"no images in {folder}")
    fps = F.estimate_fps(fr)
    print(f"frames: {len(fr)}  size: {fr[0].pixelWidth}x{fr[0].pixelHeight}  fps≈{fps:g}  segments: {len(F.segments(fr))}")
    cache = ProxyCache()
    if not fresh:
        a = cache.load_analysis(fingerprint(fr))
        if a is not None:
            a.track = build_track(a)
            print("using cached analysis", a.fingerprint)
            return a
    t0 = time.time()
    models = BirdModels()
    print("inference:", models.device_description)
    last = [0.0]

    def prog(stage, p):
        if time.time() - last[0] > 1 or p >= 1:
            last[0] = time.time()
            print(f"  {stage} {p * 100:3.0f}%")

    a = Analyzer(models).analyze(fr, fps, progress=prog)
    print(f"analysis took {time.time() - t0:.1f}s")
    cache.save_analysis(a)
    return a


def cmd_analyze(args):
    from .core.util import median, percentile
    a = _analysis(args.folder, args.fresh)
    t = a.track
    q = [p.link["quality"] for p in a.perFrame if p.link]
    print(f"bird found: {sum(p.target is not None for p in a.perFrame)}/{a.count}   eye visible: {int(t.eye_visible.sum())}/{a.count}"
          f"   links: {len(q)}  link quality median {median(q) or 0:.1f}")
    print(f"median head length {t.median_head_length:.1f} px  facingRight {t.facing_right}")


def cmd_export(args):
    from .core.exporter import VideoExporter
    from .core.render import RenderJob
    from .core.settings import (PRESETS, AspectRatio, AudioSettings, Composition, EdgeFill, ExportSettings, FrameSelection,
                                LookSettings, VideoCodec, WatermarkSettings)
    a = _analysis(args.folder)
    comp = Composition()
    if args.preset:
        comp = next(p.composition for p in PRESETS if p.id == args.preset).copy()
    if args.framing:
        comp.framing = args.framing
    if args.edge:
        comp.edgeFill = {"shift": EdgeFill.SHIFT, "zoom": EdgeFill.AUTO_ZOOM, "blur": EdgeFill.BLUR_EXTEND, "black": EdgeFill.BLACK}[args.edge]
    if args.follow is not None:
        comp.followSoftness = args.follow
    ex = ExportSettings()
    w, h = (float(x) for x in args.aspect.split(":"))
    ex.aspect = AspectRatio(w, h, args.aspect)
    ex.shortSide = args.short
    ex.outputFPS = args.fps
    ex.speed = args.speed
    ex.codec = VideoCodec(args.codec)
    ex.useFullResolution = not args.proxy
    ex.encoder = args.encoder
    ex.focusMark.enabled = args.focus
    wm = WatermarkSettings(enabled=bool(args.watermark), imagePath=args.watermark or "")
    job = RenderJob(a, comp, LookSettings(), ex, FrameSelection(), wm)
    audio = AudioSettings(path=args.audio, startOffset=args.audio_offset) if args.audio else None
    W, H = job.output_size
    print(f"export {W}x{H} {len(job.output_frames)} frames, used {len(job.used)}/{a.count}, max upscale {job.plan.max_upscale:.2f}, "
          f"decode scale {job.export_decode_scale}, shifted {job.plan.shifted_frames} zoomed {job.plan.zoomed_frames}")
    t0 = time.time()
    exp = VideoExporter()
    last = [0.0]

    def prog(p):
        if time.time() - last[0] > 2:
            last[0] = time.time()
            print(f"  {p * 100:.0f}%")

    if args.out.lower().endswith(".gif"):
        exp.export_gif(job, args.out, progress=prog)
    else:
        exp.export_video(job, args.out, audio, progress=prog)
    print(f"wrote {args.out} in {time.time() - t0:.1f}s  (encoder {exp.encoder_used})")
    if args.stills:
        import os
        from .core import frames as F
        from .core.render import OutputFrame
        os.makedirs(args.stills, exist_ok=True)
        for k in range(0, len(job.used), max(1, len(job.used) // 6)):
            i = job.used[k]
            img = job.render_output(OutputFrame(i, i, 0, 1), scale=0.5)
            F.write_jpeg(img, os.path.join(args.stills, f"still_{i:05d}.jpg"))


def cmd_devices(_args):
    import cv2
    import onnxruntime as ort
    from .core import gpu
    print("onnxruntime", ort.__version__, ort.get_available_providers())
    for ad in gpu.list_adapters():
        print(f"  adapter {ad.index}: {ad.name}  vendor {ad.vendor or hex(ad.vendor_id)}  VRAM {ad.dedicated_mb} MB"
              f"{'  (software)' if ad.software else ''}")
    b = gpu.best_adapter()
    print("best adapter:", b.name if b else None)
    print("providers for auto:", gpu.onnx_providers("auto"))
    print("OpenCL available:", cv2.ocl.haveOpenCL(), "active:", gpu.setup_opencl(True), gpu.opencl_device_name())
    print("ffmpeg:", gpu.ffmpeg_path() if hasattr(gpu, "ffmpeg_path") else None)
    print("hardware encoders:", gpu.available_encoder_families())
    print("h264 →", gpu.pick_encoder("h264"), "  hevc →", gpu.pick_encoder("hevc"))


def cmd_selftest(_args):
    """Algorithm checks that need no photos (phase correlation, trajectory solver, models, encoder)."""
    from .core.phasecorr import PhaseCorrelator
    from .core import solver
    ok = True
    rng = np.random.default_rng(1)
    n = 128
    yy, xx = np.mgrid[0:n, 0:n]
    base = np.zeros((n, n))
    for _ in range(40):
        cx, cy, r, a = rng.uniform(0, n), rng.uniform(0, n), rng.uniform(3, 14), rng.uniform(-1, 1)
        base += a * np.exp(-((xx - cx) ** 2 + (yy - cy) ** 2) / (r * r))

    def sample(dx, dy):
        fx, fy = np.fft.fftfreq(n), np.fft.fftfreq(n)
        ph = np.exp(-2j * np.pi * (fx[None, :] * dx + fy[:, None] * dy))
        return np.fft.ifft2(np.fft.fft2(base) * ph).real

    pc = PhaseCorrelator(n)
    errs = []
    for dx, dy in [(0, 0), (1.3, -0.4), (-3.7, 2.25), (6.1, 5.5), (-10.4, -0.8), (0.25, 0.75)]:
        s, q = pc.correlate(sample(0, 0), sample(dx, dy))
        errs.append(float(np.hypot(s[0] - dx, s[1] - dy)))
    print(f"phase correlation: max error {max(errs):.3f} px", "PASS" if max(errs) < 0.15 else "FAIL")
    ok &= max(errs) < 0.15

    truth = np.cumsum(rng.uniform(-5, 5, (200, 2)), 0) + 100
    meas = truth + rng.uniform(-4, 4, (200, 2))
    meas[50] += (80, -60)
    links = np.full((200, 2), np.nan)
    links[1:] = np.diff(truth, axis=0) + rng.uniform(-0.1, 0.1, (199, 2))
    links[77] += (30, 0)
    pos, _, _ = solver.solve(meas, np.full(200, 2.3), links, np.full(200, 0.06))
    jit = np.linalg.norm(np.diff(pos - truth, axis=0), axis=1).mean()
    print(f"trajectory solver: frame-to-frame jitter {jit:.3f} px", "PASS" if jit < 0.3 else "FAIL")
    ok &= jit < 0.3

    from .core.models import BirdModels
    t0 = time.time()
    m = BirdModels()
    img = np.full((1707, 2560, 3), 128, np.uint8)
    d = m.detector.detect(img)
    print(f"models: loaded in {time.time() - t0:.1f}s on {m.device_description}; blank image → {len(d)} birds",
          "PASS" if len(d) == 0 else "FAIL")
    ok &= len(d) == 0

    from .core import gpu
    enc = gpu.pick_encoder("h264")
    print("encoder:", enc, "PASS" if gpu.encoder_works(enc) else "FAIL")
    ok &= gpu.encoder_works(enc)
    print("SELFTEST", "OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="birdlock")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("selftest")
    sub.add_parser("devices")
    p = sub.add_parser("analyze")
    p.add_argument("folder")
    p.add_argument("--fresh", action="store_true")
    p = sub.add_parser("export")
    p.add_argument("folder")
    p.add_argument("--out", required=True)
    p.add_argument("--preset")
    p.add_argument("--aspect", default="16:9")
    p.add_argument("--short", type=int, default=1440)
    p.add_argument("--fps", type=float, default=30)
    p.add_argument("--speed", type=float, default=1.0)
    p.add_argument("--framing", type=float)
    p.add_argument("--edge", choices=["shift", "zoom", "blur", "black"])
    p.add_argument("--follow", type=float)
    p.add_argument("--codec", default="hevc", choices=["h264", "hevc", "proRes422HQ", "proRes4444"])
    p.add_argument("--encoder", default="auto")
    p.add_argument("--focus", action="store_true")
    p.add_argument("--audio")
    p.add_argument("--audio-offset", type=float, default=0.0)
    p.add_argument("--watermark")
    p.add_argument("--proxy", action="store_true")
    p.add_argument("--stills")
    a = ap.parse_args(argv)
    from .core import gpu, render
    render.USE_GPU_IMAGE = gpu.setup_opencl(True)
    {"selftest": cmd_selftest, "devices": cmd_devices, "analyze": cmd_analyze, "export": cmd_export}[a.cmd](a)


if __name__ == "__main__":
    main()
