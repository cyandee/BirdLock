"""Rendering one output frame (port of Render/{RenderJob, FrameRenderer, TextOverlay, FocusMark}.swift and
ExportSettings.TimeMapper).

Images are BGR uint8 numpy arrays. Heavy resampling optionally runs on the GPU via OpenCV's OpenCL path.
"""
from __future__ import annotations

import math
import os
import threading
from dataclasses import dataclass
from functools import lru_cache

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

from . import frames as F
from .analysis import ProxyCache, SequenceAnalysis, build_track
from .planner import CompositionPlan, plan as make_plan
from .settings import (Composition, EdgeFill, ExportSettings, FocusMarkStyle, FrameInterpolation, FrameSelection,
                       LookSettings, LoopMode, OverlayCorner, WatermarkSettings)
from .util import clamp, decode_scale, gaussian, median, running_median

USE_GPU_IMAGE = False     # set by gpu.setup_opencl() at start-up


# ---------------------------------------------------------------------------------------------- time mapping


@dataclass(frozen=True)
class OutputFrame:
    a: int          # source frame shown
    b: int          # blended with b by t
    t: float
    fade: float
    time: float = 0.0
    closeup: int = -1
    shotTime: float = 0.0
    audioCycle: int = 0


def output_frames(used: list[int], source_fps: float, s: ExportSettings) -> list[OutputFrame]:
    if not used:
        return []
    if s.loop == LoopMode.FORWARD:
        order = list(used)
    elif s.loop == LoopMode.REVERSE:
        order = list(reversed(used))
    else:
        order = list(used) + list(reversed(used))[1:]
    if s.repeatCount > 1:
        o = list(order)
        for _ in range(1, s.repeatCount):
            o += order[1:] if s.loop == LoopMode.PING_PONG else order
        order = o
    n = len(order)
    if n == 1:
        return [OutputFrame(order[0], order[0], 0.0, 1.0)]
    step = s.speed * source_fps / s.outputFPS
    count = int(math.floor((n - 1) / step)) + 1
    total = count / s.outputFPS
    out = []
    for k in range(count):
        pos = k * step
        i0 = min(n - 1, int(math.floor(pos)))
        i1 = min(n - 1, i0 + 1)
        fr = pos - i0
        time = k / s.outputFPS
        fade = 1.0
        if s.fadeInSeconds > 0:
            fade = min(fade, time / s.fadeInSeconds)
        if s.fadeOutSeconds > 0:
            fade = min(fade, (total - time) / s.fadeOutSeconds)
        fade = clamp(fade, 0.0, 1.0)
        if s.interpolation == FrameInterpolation.NEAREST:
            idx = i0 if fr < 0.5 else i1
            out.append(OutputFrame(order[idx], order[idx], 0.0, fade, time))
        else:
            out.append(OutputFrame(order[i0], order[i1], 0.0 if fr < 1e-6 else fr, fade, time))
    return out


def project_frames(used, clips, closeups, source_fps, settings):
    from dataclasses import replace
    local = settings.copy()
    local.loop, local.repeatCount, local.fadeInSeconds, local.fadeOutSeconds = LoopMode.FORWARD, 1, 0, 0
    base = []
    for clip in clips:
        indices = [i for i in used if clip["start"] <= i < clip["start"] + clip["count"]]
        base += output_frames(indices, clip["fps"] if clip["fps"] > 0 else source_fps, local)
    if not clips:
        base = output_frames(used, source_fps, local)
    arranged, active = [], None
    available = set(used)
    for frame in base:
        match = next((i for i,s in enumerate(closeups) if s.frame in available and s.frame <= frame.a <= max(s.frame,s.endFrame)), None)
        if match is None:
            arranged.append(frame)
        elif match != active:
            shot = closeups[match]
            count = max(1, math.floor(min(3600,max(1/settings.outputFPS,shot.seconds))*settings.outputFPS+0.5))
            arranged += [OutputFrame(shot.frame,shot.frame,0,1,closeup=match,shotTime=k/settings.outputFPS) for k in range(count)]
        active = match
    if settings.loop == LoopMode.REVERSE:
        arranged.reverse()
    elif settings.loop == LoopMode.PING_PONG:
        arranged += list(reversed(arranged))[1:]
    cycle = list(arranged)
    for repetition in range(1,settings.repeatCount):
        arranged += [replace(f,audioCycle=repetition) for f in (cycle[1:] if settings.loop == LoopMode.PING_PONG else cycle)]
    duration = len(arranged)/settings.outputFPS
    result = []
    for k,frame in enumerate(arranged):
        time, fade = k/settings.outputFPS,1
        if settings.fadeInSeconds>0:fade=min(fade,time/settings.fadeInSeconds)
        if settings.fadeOutSeconds>0:fade=min(fade,(duration-time)/settings.fadeOutSeconds)
        result.append(replace(frame,time=time,fade=clamp(fade,0,1)))
    return result


# ---------------------------------------------------------------------------------------------- deflicker


def deflicker_gains(a: SequenceAnalysis, look: LookSettings) -> np.ndarray:
    """Per-frame RGB gains (n, 3) removing exposure / white-balance flicker."""
    if len(a.clips) > 1:
        from dataclasses import replace
        return np.concatenate([deflicker_gains(replace(a,frames=a.frames[c["start"]:c["start"]+c["count"]],
            perFrame=a.perFrame[c["start"]:c["start"]+c["count"]],clips=[]),look) for c in a.clips])
    n = a.count
    ev = 2 ** look.exposureEV
    out = np.full((n, 3), ev)
    if not look.deflicker or n <= 2:
        return out
    for ch in range(3):
        lg = np.array([math.log(p.bgLinear[ch]) if p.bgLinear[ch] > 1e-5 else np.nan for p in a.perFrame])
        tgt = gaussian(running_median(lg, int(look.deflickerWindow)), look.deflickerWindow)
        ok = np.isfinite(lg) & np.isfinite(tgt)
        g = np.exp((tgt - lg) * look.deflickerStrength)
        out[ok, ch] = np.clip(g[ok], 0.5, 2.0) * ev
    return out


_SRGB2LIN = np.array([c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in np.arange(256) / 255.0],
                     dtype=np.float32)
_LIN2SRGB = np.clip(np.round(np.array([12.92 * v if v <= 0.0031308 else 1.055 * v ** (1 / 2.4) - 0.055
                                       for v in np.arange(4096) / 4095.0]) * 255), 0, 255).astype(np.uint8)
_SRGB2LIN.flags.writeable = False
_LIN2SRGB.flags.writeable = False


def apply_gains(img: np.ndarray, gains_rgb) -> np.ndarray:
    g = np.asarray(gains_rgb, dtype=np.float32)
    if g.shape != (3,):
        raise ValueError("色彩增益必须包含 RGB 三个值")
    if not np.all(np.isfinite(g)):
        from .log import log
        log.warning("non-finite color gains sanitized")
        g = np.nan_to_num(g, nan=1.0, posinf=16.0, neginf=0.0)
    if np.all(np.abs(g - 1) < 1e-4):
        return img
    # Build a tiny BGR lookup once per frame instead of allocating float images
    # and a full-resolution int32 index image in every rendering worker.
    with np.errstate(over='ignore'):
        linear = _SRGB2LIN[:, None] * g[::-1][None, :]
        idx = np.clip(linear * 4095 + 0.5, 0, 4095).astype(np.intp)
    table = _LIN2SRGB[idx].reshape(1, 256, 3)
    return cv2.LUT(img, table)


# ---------------------------------------------------------------------------------------------- resampling helpers


def _resize(img, size, interp):
    if USE_GPU_IMAGE:
        try:
            return cv2.resize(cv2.UMat(img), size, interpolation=interp).get()
        except cv2.error:
            pass
    return cv2.resize(img, size, interpolation=interp)


def _warp(img, M, size, interp, border, value=0):
    if USE_GPU_IMAGE:
        try:
            return cv2.warpAffine(cv2.UMat(img), M, size, flags=interp, borderMode=border, borderValue=value).get()
        except cv2.error:
            pass
    return cv2.warpAffine(img, M, size, flags=interp, borderMode=border, borderValue=value)


def _to_pixel_centers(A: np.ndarray) -> np.ndarray:
    """Continuous-coordinate affine (pixel i covers [i, i+1)) → OpenCV pixel-centre convention."""
    L = A[:, :2]
    t = A[:, 2] + L @ np.array([0.5, 0.5]) - 0.5
    return np.hstack([L, t[:, None]])


def _compose_affine(A: np.ndarray, B: np.ndarray) -> np.ndarray:
    """A ∘ B for 2×3 affines."""
    A3 = np.vstack([A, [0, 0, 1]])
    B3 = np.vstack([B, [0, 0, 1]])
    return (A3 @ B3)[:2]


def alpha_composite(dst: np.ndarray, rgba: np.ndarray, x: int, y: int, opacity: float = 1.0):
    """Blend a BGRA image onto dst (BGR, in place) with its top-left at (x, y)."""
    h, w = rgba.shape[:2]
    H, W = dst.shape[:2]
    x0, y0, x1, y1 = max(0, x), max(0, y), min(W, x + w), min(H, y + h)
    if x1 <= x0 or y1 <= y0:
        return
    src = rgba[y0 - y:y1 - y, x0 - x:x1 - x]
    a = src[..., 3:4].astype(np.float32) * (opacity / 255.0)
    roi = dst[y0:y1, x0:x1]
    roi[:] = (src[..., :3].astype(np.float32) * a + roi.astype(np.float32) * (1 - a) + 0.5).astype(np.uint8)


# ---------------------------------------------------------------------------------------------- text & marks


def _font_candidates():
    if os.name == "nt":
        windir = os.environ.get("WINDIR", "C:\\Windows")
        return [os.path.join(windir, "Fonts", f) for f in ("msyh.ttc", "msyhbd.ttc", "simhei.ttf", "simsun.ttc", "arial.ttf")]
    return ["/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/STHeiti Light.ttc", "/System/Library/Fonts/Hiragino Sans GB.ttc",
            "/Library/Fonts/Arial Unicode.ttf", "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"]


@lru_cache(maxsize=16)
def _font(size: int):
    for p in _font_candidates():
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                continue
    return ImageFont.load_default()


@lru_cache(maxsize=64)
def text_block(lines: tuple[str, ...], font_size: int) -> np.ndarray | None:
    """White text with a soft shadow on transparent background (BGRA)."""
    lines = tuple(l for l in lines if l)
    if not lines:
        return None
    font = _font(max(6, font_size))
    pad = int(font_size * 0.5)
    line_h = int(font_size * 1.35)
    widths = [font.getbbox(l)[2] for l in lines]
    W, H = int(max(widths) + 2 * pad), int(line_h * len(lines) + 2 * pad)
    shadow = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(shadow)
    for i, l in enumerate(lines):
        d.text((pad, pad + i * line_h + font_size * 0.06), l, font=font, fill=150)
    shadow = shadow.filter(ImageFilter.GaussianBlur(font_size * 0.25))
    text = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(text)
    for i, l in enumerate(lines):
        d.text((pad, pad + i * line_h), l, font=font, fill=255)
    t = np.asarray(text, np.float32) / 255
    s = np.asarray(shadow, np.float32) / 255
    alpha = t + s * (1 - t)
    rgb = np.where(alpha > 1e-6, t / np.maximum(alpha, 1e-6), 0) * 255
    out = np.zeros((H, W, 4), np.uint8)
    out[..., 0] = out[..., 1] = out[..., 2] = rgb.astype(np.uint8)
    out[..., 3] = (alpha * 255).astype(np.uint8)
    return out


def overlay_lines(exif, o) -> tuple[str, ...]:
    out = []
    if o.customText:
        out.append(o.customText)
    if o.showExif:
        gear = [x for x in (exif.camera_name, exif.lens) if x]
        if gear:
            out.append(" · ".join(gear))
        if exif.exposure_line:
            out.append(exif.exposure_line)
    return tuple(out)


def project_source_time(frame, output_frames, closeups):
    """First occurrence in output, resolving replaced photos; None for omitted photos."""
    for index, shot in enumerate(closeups):
        if shot.frame <= frame <= max(shot.frame, shot.endFrame):
            match = next((of for of in output_frames if of.closeup == index), None)
            if match is not None:
                return match.time
    return next((of.time for of in output_frames if of.a == frame), None)


def draw_focus_mark(img: np.ndarray, center, side: float, line: int, style: FocusMarkStyle, bgr, height=None):
    """Camera-style AF frame: thin coloured square or corner brackets with a faint dark outline."""
    sh = 4                                    # fixed-point bits for sub-pixel drawing
    S = 1 << sh
    cx, cy = center
    half_w, half_h = side / 2, (height if height is not None else side) / 2
    x0, y0, x1, y1 = cx - half_w, cy - half_h, cx + half_w, cy + half_h

    def pt(x, y):
        return int(round(x * S)), int(round(y * S))

    if style == FocusMarkStyle.BOX:
        segs = [((x0, y0), (x1, y0)), ((x1, y0), (x1, y1)), ((x1, y1), (x0, y1)), ((x0, y1), (x0, y0))]
    else:
        L = min(side, height if height is not None else side) * 0.28
        segs = []
        for (px, py, dx, dy) in ((x0, y0, 1, 1), (x1, y0, -1, 1), (x0, y1, 1, -1), (x1, y1, -1, -1)):
            segs += [((px, py + dy * L), (px, py)), ((px, py), (px + dx * L, py))]
    pad = line + 4
    rx0, ry0 = max(0, int(x0) - pad), max(0, int(y0) - pad)
    rx1, ry1 = min(img.shape[1], int(x1) + pad + 1), min(img.shape[0], int(y1) + pad + 1)
    if rx1 <= rx0 or ry1 <= ry0:
        return
    roi = img[ry0:ry1, rx0:rx1]
    shade = roi.copy()
    for a, b in segs:
        cv2.line(shade, pt(a[0] - rx0, a[1] - ry0), pt(b[0] - rx0, b[1] - ry0), (0, 0, 0), line + 2, cv2.LINE_AA, sh)
    cv2.addWeighted(shade, 0.35, roi, 0.65, 0, dst=roi)
    for a, b in segs:
        cv2.line(roi, pt(a[0] - rx0, a[1] - ry0), pt(b[0] - rx0, b[1] - ry0), bgr, line, cv2.LINE_AA, sh)


def load_watermark(path: str) -> np.ndarray | None:
    img = F.read_file_image(path, cv2.IMREAD_UNCHANGED)
    if img is None:
        return None
    if img.ndim == 2:
        img = cv2.cvtColor(img, cv2.COLOR_GRAY2BGRA)
    elif img.shape[2] == 3:
        img = cv2.cvtColor(img, cv2.COLOR_BGR2BGRA)
    if img.dtype != np.uint8:
        img = (img / 257).astype(np.uint8)
    return img


# ---------------------------------------------------------------------------------------------- render job


STATUS_OK, STATUS_EXCLUDED, STATUS_BLURRY, STATUS_UNTRACKED, STATUS_TRIMMED = "ok", "excluded", "blurry", "untracked", "trimmed"


class RenderJob:
    """Everything needed to render frames for one set of settings."""

    def __init__(self, analysis: SequenceAnalysis, composition: Composition, look: LookSettings, export: ExportSettings,
                 selection: FrameSelection, watermark: WatermarkSettings | None = None, cache: ProxyCache | None = None):
        self.analysis = analysis
        self.track = analysis.track or build_track(analysis)
        self.composition, self.look, self.export, self.selection = composition, look, export, selection
        self.watermark = watermark or WatermarkSettings()
        self.cache = cache or ProxyCache()
        n = analysis.count
        sharp = np.array([p.sharpness if p.sharpness is not None else np.nan for p in analysis.perFrame])
        med_sharp = median(sharp) or 0.0
        end = min(n - 1, selection.trimEnd if selection.trimEnd >= 0 else n - 1)
        st = []
        for i in range(n):
            if i < selection.trimStart or i > end:
                st.append(STATUS_TRIMMED)
            elif i in analysis.excluded:
                st.append(STATUS_EXCLUDED)
            elif selection.dropUntracked and not self.track.has_data[i]:
                st.append(STATUS_UNTRACKED)
            elif selection.dropBlurry and math.isfinite(sharp[i]) and med_sharp > 0 and sharp[i] < med_sharp * selection.blurThreshold:
                st.append(STATUS_BLURRY)
            else:
                st.append(STATUS_OK)
        self.status = st
        self.used = [i for i in range(n) if st[i] == STATUS_OK]
        W, H = export.output_size
        self.plan: CompositionPlan = make_plan(self.track, analysis.frames, composition, float(W), float(H), self.used or None)
        if len(analysis.clips) > 1:
            from dataclasses import replace
            parts=[]
            for clip in analysis.clips:
                start,stop=clip["start"],clip["start"]+clip["count"]
                sub=replace(self.track, **{name:getattr(self.track,name)[start:stop] for name in ("eye","head_center","head_length","angle","measured_eye","eye_visible","has_data","confidence")})
                sub.median_head_length=float(np.median(sub.head_length))
                sub.facing_right=float(np.median(np.cos(sub.angle)))>=0
                parts.append(make_plan(sub,analysis.frames[start:stop],composition,float(W),float(H),[i-start for i in self.used if start<=i<stop]))
            self.plan=CompositionPlan([x for p in parts for x in p.xforms],float(W),float(H),max(p.max_upscale for p in parts),
                 sum(p.out_of_bounds_frames for p in parts),sum(p.shifted_frames for p in parts),sum(p.zoomed_frames for p in parts),
                 sum(p.image_limited_frames for p in parts),parts[0].mirrored)
        self.gains = deflicker_gains(analysis, look)
        self.output_frames = project_frames(self.used, analysis.clips, analysis.closeups, analysis.fps, export) if analysis.clips or analysis.closeups else output_frames(self.used, analysis.fps, export)
        self._wm_img = None
        self._wm_loaded = False
        self._lock = threading.Lock()

    def mixed_audio(self, user_audio=None):
        from .settings import AudioSettings
        from .closeup_audio import tracks
        result = user_audio.copy() if user_audio else AudioSettings()
        result.tracks += tracks(self.output_frames,self.analysis.closeups)
        return result

    @property
    def output_size(self) -> tuple[int, int]:
        return self.export.output_size

    @property
    def duration(self) -> float:
        return len(self.output_frames) / self.export.outputFPS

    def contains(self, i: int) -> bool:
        return 0 <= i < self.analysis.count and i < len(self.plan.xforms)

    def preview_frame(self, frame):
        from dataclasses import replace
        for i,shot in enumerate(self.analysis.closeups):
            if shot.frame <= frame <= max(shot.frame,shot.endFrame):
                match=next((of for of in self.output_frames if of.closeup==i),None)
                if match is not None:return replace(match,shotTime=0.35)
        return OutputFrame(frame,frame,0,1)

    @property
    def export_decode_scale(self) -> float:
        return decode_scale(min(1.0, self.plan.max_upscale * max([1] + [s.zoom for s in self.analysis.closeups]) * 1.2))

    def source(self, i: int, proxy: bool, scale: float = 1.0):
        """(image, scale relative to the original pixel grid) or None."""
        if not (0 <= i < self.analysis.count):
            return None
        f = self.analysis.frames[i]
        if proxy:
            p = self.cache.load_proxy(self.analysis.fingerprint, i)
            if p is not None:
                return p, p.shape[1] / f.pixelWidth
        img = F.load_image(f, scale)
        if img is None:
            return None
        return img, img.shape[1] / f.pixelWidth

    # -- composition

    def out_dims(self, scale: float) -> tuple[int, int]:
        W, H = self.output_size
        return max(2, int(round(W * scale))), max(2, int(round(H * scale)))

    def compose(self, i: int, src: np.ndarray, source_scale: float, scale: float = 1.0) -> np.ndarray:
        w, h = self.out_dims(scale)
        if not self.contains(i):
            return np.zeros((h, w, 3), np.uint8)
        xf = self.plan.xforms[i].scaled(w / self.output_size[0])
        A = _compose_affine(xf.matrix(), np.array([[1 / source_scale, 0, 0], [0, 1 / source_scale, 0]]))
        z_eff = xf.z / source_scale
        work = src
        if z_eff < 0.6:
            # crop the needed region (with margin), high-quality pre-downscale, then a near-unit residual warp
            quad = np.array(xf.source_quad(w, h)) * source_scale
            margin = 8 / z_eff
            Hs, Ws = src.shape[:2]
            x0 = int(max(0, math.floor(quad[:, 0].min() - margin)))
            y0 = int(max(0, math.floor(quad[:, 1].min() - margin)))
            x1 = int(min(Ws, math.ceil(quad[:, 0].max() + margin)))
            y1 = int(min(Hs, math.ceil(quad[:, 1].max() + margin)))
            if x1 - x0 > 2 and y1 - y0 > 2:
                roi = src[y0:y1, x0:x1]
                nw, nh = max(1, int(round((x1 - x0) * z_eff))), max(1, int(round((y1 - y0) * z_eff)))
                work = _resize(roi, (nw, nh), cv2.INTER_AREA)
                fx, fy = nw / (x1 - x0), nh / (y1 - y0)
                A = _compose_affine(A, np.array([[1 / fx, 0, x0], [0, 1 / fy, y0]]))
        Mc = _to_pixel_centers(A)
        if self.composition.edgeFill == EdgeFill.BLUR_EXTEND:
            sharp = _warp(work, Mc, (w, h), cv2.INTER_CUBIC, cv2.BORDER_CONSTANT)
            bg = _warp(work, Mc, (w, h), cv2.INTER_LINEAR, cv2.BORDER_REPLICATE)
            bg = cv2.GaussianBlur(bg, (0, 0), max(1.0, min(w, h) * 0.02))
            mask = _warp(np.full(work.shape[:2], 255, np.uint8), Mc, (w, h), cv2.INTER_LINEAR, cv2.BORDER_CONSTANT)
            a = (mask.astype(np.float32) / 255)[..., None]
            out = (sharp * a + bg * (1 - a) + 0.5).astype(np.uint8)
        else:
            out = _warp(work, Mc, (w, h), cv2.INTER_CUBIC, cv2.BORDER_CONSTANT)
        return apply_gains(out, self.gains[i])

    # -- overlays

    def _text_overlay(self, i: int, w: int, h: int):
        o = self.export.overlay
        if not (o.showExif or o.customText):
            return None
        frames = self.analysis.frames
        exif = frames[i].exif if o.exifPerFrame else (frames[0].exif if frames else None)
        lines = overlay_lines(exif, o)
        fs = int(round(min(w, h) * 0.022 * o.textScale))
        img = text_block(lines, fs)
        if img is None:
            return None
        m = min(w, h) * 0.03
        tw, th = img.shape[1], img.shape[0]
        pos = {OverlayCorner.TOP_LEFT: (m, m), OverlayCorner.TOP_RIGHT: (w - tw - m, m),
               OverlayCorner.BOTTOM_LEFT: (m, h - th - m), OverlayCorner.BOTTOM_RIGHT: (w - tw - m, h - th - m)}[o.corner]
        return img, int(round(pos[0])), int(round(pos[1])), o.opacity

    def watermark_image(self) -> np.ndarray | None:
        if not self.watermark.active:
            return None
        with self._lock:
            if not self._wm_loaded:
                self._wm_img = load_watermark(self.watermark.imagePath)
                self._wm_loaded = True
            return self._wm_img

    def focus_target(self, i: int, scale: float):
        """(centre (output px at `scale`), frame side) where a camera would show its AF frame, or None."""
        if not self.contains(i) or not self.track.has_data[i]:
            return None
        fm = self.export.focusMark
        xf = self.plan.xforms[i].scaled(scale)
        aircraft = getattr(self.analysis, "subject", "bird") == "aircraft"
        eye_seen = not aircraft and (bool(self.track.eye_visible[i]) or i in self.analysis.manualEye)
        on_head = not eye_seen and fm.headWhenHidden
        if aircraft:
            on_head = True
        side = self.track.head_length[i] * xf.z * (1.3 if on_head else 0.42) * fm.size
        c = xf.map(self.track.head_center[i] if on_head else self.track.eye[i])
        return c, max(10 * scale, side)

    # -- full output frame

    def focus_rect(self, i: int, target: str, scale: float):
        aircraft = getattr(self.analysis, "subject", "bird") == "aircraft"
        if aircraft and target == "eye":
            return None
        if not self.contains(i) or (not self.track.has_data[i] and not (aircraft and target == "body")):
            return None
        if target == "eye":
            value = self.focus_target(i, scale)
            return None if value is None else np.array([*value[0], value[1], value[1]])
        xf = self.plan.xforms[i].scaled(scale)
        if target == "head":
            side = max(10 * scale, self.track.head_length[i] * xf.z * 1.3 * self.export.focusMark.size)
            return np.array([*xf.map(self.track.head_center[i]), side, side])
        pf = self.analysis.perFrame[i]
        box = pf.target_box
        if target != "body" or box is None:
            return None
        x0,y0,x1,y1 = box.x,box.y,box.x+box.w,box.y+box.h
        if aircraft and self.track.has_data[i]:
            nose = pf.aircraft.nose if pf.aircraft is not None else None
            # COCO sometimes encloses only the wings/fuselage. Include the independently located
            # nose in the displayed whole-airframe frame, keeping the raw detector box unchanged.
            if nose is not None or i in self.analysis.manualEye:
                center = self.track.head_center[i]
                w,h = (nose.w,nose.h) if nose is not None else (self.track.head_length[i],self.track.head_length[i])
                x0,y0 = min(x0,center[0]-w/2),min(y0,center[1]-h/2)
                x1,y1 = max(x1,center[0]+w/2),max(y1,center[1]+h/2)
        points = np.array([xf.map(q) for q in [(x0,y0),(x1,y0),(x0,y1),(x1,y1)]])
        lo, hi = points.min(axis=0), points.max(axis=0)
        size = (hi - lo) * clamp(self.export.focusMark.bodySize, 0.5, 2.5) * 1.04
        return np.array([*((lo + hi) / 2), *size])

    def render_output(self, of: OutputFrame, scale: float = 1.0, include_watermark: bool = True, fetch=None,
                      interpolate=None) -> np.ndarray | None:
        if not (self.contains(of.a) and self.contains(of.b)):
            return None
        fetch = fetch or (lambda i: self.source(i, True))
        sa = fetch(of.a)
        if sa is None:
            return None
        img = self.compose(of.a, sa[0], sa[1], scale)
        if of.t > 0.001 and of.b != of.a:
            sb = fetch(of.b)
            if sb is not None:
                b = self.compose(of.b, sb[0], sb[1], scale)
                mixed = interpolate(img, b, of.t) if interpolate else None
                img = mixed if mixed is not None else cv2.addWeighted(img, 1 - of.t, b, of.t, 0)
        h, w = img.shape[:2]
        sx = w / self.output_size[0]
        fm = self.export.focusMark
        flash_on = fm.flash_on(of.time)
        if fm.enabled:
            for target, enabled in [("eye", fm.showEye), ("head", fm.showHead),
                                    ("body", fm.showBody and (not fm.blinkBody or flash_on))]:
                if not enabled:
                    continue
                rect = self.focus_rect(of.a, target, sx)
                if rect is None:
                    continue
                if of.t > 0.001 and of.b != of.a:
                    other = self.focus_rect(of.b, target, sx)
                    if other is not None:
                        rect = rect + (other - rect) * of.t
                line = max(1, int(round(min(w, h) * 0.0024 * fm.lineWidth)))
                draw_focus_mark(img, rect[:2], rect[2], line, fm.style, fm.color_for(target).bgr, height=rect[3])
        if 0 <= of.closeup < len(self.analysis.closeups):
            shot = self.analysis.closeups[of.closeup]
            zoom = clamp(shot.zoom,1,8)
            cx,cy=clamp(shot.centerX,0.5/zoom,1-0.5/zoom),clamp(shot.centerY,0.5/zoom,1-0.5/zoom)
            matrix=np.array([[zoom,0,w*(0.5-cx*zoom)],[0,zoom,h*(0.5-cy*zoom)]],dtype=np.float64)
            img=cv2.warpAffine(img,matrix,(w,h),flags=cv2.INTER_CUBIC,borderMode=cv2.BORDER_REPLICATE)
            if shot.animatedFrame:
                fraction=0.84+0.08*(1-(1-min(1,of.shotTime/0.35))**3)
                layer=img.copy()
                from .settings import FocusMarkStyle
                draw_focus_mark(layer,(w/2,h/2),w*fraction,max(1,round(min(w,h)*0.002)),FocusMarkStyle.BRACKETS,shot.color.bgr,height=h*fraction)
                alpha=0.7+0.3*math.sin(of.shotTime*math.pi*2)
                img=cv2.addWeighted(layer,alpha,img,1-alpha,0)
        if fm.captureFlash and flash_on:
            layer = img.copy()
            fraction = clamp(fm.captureSize, 0.25, 0.98)
            px, py = round(w * (1 - fraction) / 2), round(h * (1 - fraction) / 2)
            cv2.rectangle(layer, (px, py), (w - px - 1, h - py - 1), fm.captureColor.bgr,
                          max(1, round(min(w, h) * 0.0012)), cv2.LINE_AA)
            img = cv2.addWeighted(layer, 0.55, img, 0.45, 0)
        ov = self._text_overlay(of.a, w, h)
        if ov is not None:
            alpha_composite(img, ov[0], ov[1], ov[2], ov[3])
        if include_watermark:
            wm = self.watermark_image()
            if wm is not None:
                x, y, ww, hh = self.watermark.rect(wm.shape[1], wm.shape[0], w, h)
                if ww >= 1:
                    sw, shh = max(1, int(round(ww))), max(1, int(round(hh)))
                    placed = cv2.resize(wm, (sw, shh), interpolation=cv2.INTER_AREA if sw < wm.shape[1] else cv2.INTER_CUBIC)
                    alpha_composite(img, placed, int(round(x)), int(round(y)), self.watermark.opacity)
        if of.fade < 0.999:
            img = (img.astype(np.float32) * of.fade + 0.5).astype(np.uint8)
        return img


# ---------------------------------------------------------------------------------------------- optical-flow interpolation


class FlowInterpolator:
    """Motion-compensated in-between frames (DIS optical flow, computed at half resolution)."""

    def __init__(self):
        self.dis = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)
        self._lock = threading.Lock()

    def __call__(self, a: np.ndarray, b: np.ndarray, t: float) -> np.ndarray:
        h, w = a.shape[:2]
        sw, sh = max(16, w // 2), max(16, h // 2)
        ga = cv2.cvtColor(cv2.resize(a, (sw, sh), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2GRAY)
        gb = cv2.cvtColor(cv2.resize(b, (sw, sh), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2GRAY)
        with self._lock:
            fab = self.dis.calc(ga, gb, None)
            fba = self.dis.calc(gb, ga, None)
        fab = cv2.resize(fab, (w, h), interpolation=cv2.INTER_LINEAR) * (w / sw)
        fba = cv2.resize(fba, (w, h), interpolation=cv2.INTER_LINEAR) * (w / sw)
        gx, gy = np.meshgrid(np.arange(w, dtype=np.float32), np.arange(h, dtype=np.float32))
        # backward warps: the intermediate pixel came from a at x − t·F_ab and from b at x − (1−t)·F_ba
        wa = cv2.remap(a, gx - t * fab[..., 0], gy - t * fab[..., 1], cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
        wb = cv2.remap(b, gx - (1 - t) * fba[..., 0], gy - (1 - t) * fba[..., 1], cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
        return cv2.addWeighted(wa, 1 - t, wb, t, 0)
