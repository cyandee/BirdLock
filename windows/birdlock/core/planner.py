"""Composition planning (port of Render/CompositionPlanner.swift).

Mapping from source pixels (top-left origin) to output pixels:   o = p + z · R(psi) · (q − a)
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from .settings import Composition, EdgeFill, LockPoint, RotationMode, SizeMode
from .util import clamp, gaussian, median, running_max


@dataclass
class FrameXform:
    a: np.ndarray    # source anchor
    p: np.ndarray    # output anchor position
    z: float         # output px per source px
    psi: float       # rotation (radians, image coords)
    valid: bool

    def map(self, q) -> np.ndarray:
        d = np.asarray(q, dtype=np.float64) - self.a
        c, s = math.cos(self.psi), math.sin(self.psi)
        return self.p + self.z * np.array([c * d[0] - s * d[1], s * d[0] + c * d[1]])

    def unmap(self, o) -> np.ndarray:
        d = (np.asarray(o, dtype=np.float64) - self.p) / self.z
        c, s = math.cos(-self.psi), math.sin(-self.psi)
        return self.a + np.array([c * d[0] - s * d[1], s * d[0] + c * d[1]])

    def matrix(self) -> np.ndarray:
        """2×3 affine (continuous top-left coordinates): o = M · [q, 1]."""
        c, s = math.cos(self.psi) * self.z, math.sin(self.psi) * self.z
        tx = self.p[0] - (c * self.a[0] - s * self.a[1])
        ty = self.p[1] - (s * self.a[0] + c * self.a[1])
        return np.array([[c, -s, tx], [s, c, ty]])

    def source_quad(self, out_w: float, out_h: float) -> list[np.ndarray]:
        return [self.unmap(v) for v in ((0, 0), (out_w, 0), (out_w, out_h), (0, out_h))]

    def scaled(self, k: float) -> "FrameXform":
        return FrameXform(self.a, self.p * k, self.z * k, self.psi, self.valid)


@dataclass
class CompositionPlan:
    xforms: list
    out_w: float
    out_h: float
    max_upscale: float
    out_of_bounds_frames: int
    shifted_frames: int = 0
    zoomed_frames: int = 0
    image_limited_frames: int = 0
    mirrored: bool = False


def _rotate(v: np.ndarray, a: float) -> np.ndarray:
    c, s = math.cos(a), math.sin(a)
    return np.array([c * v[0] - s * v[1], s * v[0] + c * v[1]])


def plan(track, frames, c: Composition, out_w: float, out_h: float, used: list[int] | None = None) -> CompositionPlan:
    n = track.count
    used_idx = used if used else list(range(n))
    used_set = set(used_idx)

    src = track.eye if c.lockPoint == LockPoint.EYE else track.head_center
    ax, ay = src[:, 0].copy(), src[:, 1].copy()
    if c.followSoftness > 0.001:
        sigma = c.followSoftness * 25
        ax, ay = gaussian(ax, sigma), gaussian(ay, sigma)

    hl = track.head_length
    med_hl = median([hl[i] for i in used_idx]) or track.median_head_length
    if c.sizeMode == SizeMode.FIXED_CROP:
        ref_hl = np.full(n, med_hl)
    else:
        ref_hl = np.exp(gaussian(np.log(hl), max(2.0, c.sizeSmoothing)))

    ang = track.angle
    med_ang = median([ang[i] for i in used_idx]) or 0.0
    off = c.rotationOffsetDeg * math.pi / 180
    if c.rotationMode == RotationMode.NONE:
        psi = np.full(n, off)
    elif c.rotationMode == RotationMode.LOCK_HEAD:
        psi = -(gaussian(ang, 2) - med_ang) + off
    else:
        psi = -0.7 * (gaussian(ang, 20) - med_ang) + off

    facing_right = math.cos(med_ang + off) >= 0
    u = c.anchorX
    mirrored = c.autoLeadRoom and not facing_right
    if mirrored:
        u = 1 - u
    p = np.array([u * out_w, c.anchorY * out_h])
    short = min(out_w, out_h)
    corners = [np.array(v, dtype=np.float64) for v in ((0, 0), (out_w, 0), (0, out_h), (out_w, out_h))]
    z = short / (max(1e-3, c.framing) * ref_hl)

    def img_size(i):
        return np.array([frames[i].pixelWidth, frames[i].pixelHeight], dtype=np.float64)

    def crop_box(i, zz):
        e = np.array([_rotate(o - p, -psi[i]) / zz for o in corners])
        a = np.array([ax[i], ay[i]])
        return a + e.min(0), a + e.max(0)

    # zoom needed to keep the crop inside the photo with the anchor fixed
    need = np.ones(n)
    oob = 0
    for i in range(n):
        ws, hs = img_size(i)
        a = np.array([ax[i], ay[i]])
        zmin = 0.0
        for o in corners:
            cv = _rotate(o - p, -psi[i])
            if cv[0] < 0:
                zmin = max(zmin, -cv[0] / a[0] if a[0] > 0 else math.inf)
            if cv[0] > 0:
                zmin = max(zmin, cv[0] / (ws - a[0]) if ws - a[0] > 0 else math.inf)
            if cv[1] < 0:
                zmin = max(zmin, -cv[1] / a[1] if a[1] > 0 else math.inf)
            if cv[1] > 0:
                zmin = max(zmin, cv[1] / (hs - a[1]) if hs - a[1] > 0 else math.inf)
        need[i] = max(1.0, zmin / z[i])
        if need[i] > 1.0001 and i in used_set:
            oob += 1

    def fit_shift(i, zz):
        lo, hi = crop_box(i, zz)
        s = img_size(i)
        if hi[0] - lo[0] > s[0] + 1e-6 or hi[1] - lo[1] > s[1] + 1e-6:
            return None
        return np.array([clamp(0.0, -lo[0], s[0] - hi[0]), clamp(0.0, -lo[1], s[1] - hi[1])])

    def anchor_after(i, zz, t):
        return p - zz * _rotate(t, psi[i])

    def kfit_of(i):
        lo, hi = crop_box(i, z[i])
        s = img_size(i)
        return max(1.0, (hi[0] - lo[0]) / s[0], (hi[1] - lo[1]) / s[1]) * (1 + 1e-9)

    def slide_inside():
        dx, dy = np.zeros(n), np.zeros(n)
        for i in range(n):
            t = fit_shift(i, z[i])
            d = anchor_after(i, z[i], t if t is not None else np.zeros(2)) - p
            dx[i], dy[i] = d

        def ease(v):
            pos = gaussian(running_max(np.maximum(0, v), 5), 2.5)
            neg = gaussian(running_max(np.maximum(0, -v), 5), 2.5)
            return np.maximum(pos, np.maximum(0, v)) - np.maximum(neg, np.maximum(0, -v))

        dx, dy = ease(dx), ease(dy)
        out = []
        for i in range(n):
            t = -_rotate(np.array([dx[i], dy[i]]), -psi[i]) / z[i]
            lo, hi = crop_box(i, z[i])
            s = img_size(i)
            t[0] = clamp(t[0], -lo[0], s[0] - hi[0]) if hi[0] - lo[0] <= s[0] + 1e-6 else (s[0] - lo[0] - hi[0]) / 2
            t[1] = clamp(t[1], -lo[1], s[1] - hi[1]) if hi[1] - lo[1] <= s[1] + 1e-6 else (s[1] - lo[1] - hi[1]) / 2
            out.append(anchor_after(i, z[i], t))
        return out

    anchors = [p.copy() for _ in range(n)]
    zoomed = limited = 0
    if c.edgeFill == EdgeFill.AUTO_ZOOM:
        capped = np.array([min(need[i] if math.isfinite(need[i]) else 8.0, max(8.0, kfit_of(i))) for i in range(n)])
        r = gaussian(running_max(capped, 9), 3)
        for i in range(n):
            kk = max(r[i], capped[i])
            z[i] *= kk
            if i in used_set and kk > 1.001:
                zoomed += 1
        anchors = slide_inside()
    elif c.edgeFill == EdgeFill.SHIFT:
        m = clamp(c.edgeMargin, 0.0, 0.45)
        safe_lo = np.array([min(m * out_w, p[0]), min(m * out_h, p[1])])
        safe_hi = np.array([max((1 - m) * out_w, p[0]), max((1 - m) * out_h, p[1])])

        def in_safe(q):
            return (q >= safe_lo - 0.5).all() and (q <= safe_hi + 0.5).all()

        k = np.ones(n)
        kfit = np.ones(n)
        for i in range(n):
            kfit[i] = kfit_of(i)

            def ok(kk):
                t = fit_shift(i, z[i] * kk)
                return t is not None and in_safe(anchor_after(i, z[i] * kk, t))

            lo2 = kfit[i]
            if ok(lo2):
                k[i] = lo2
                continue
            kmax = kfit[i] * max(1.0, c.maxEdgeZoom)
            if not ok(kmax):
                k[i] = kmax
                continue
            hi2 = kmax
            for _ in range(24):
                mid = 0.5 * (lo2 + hi2)
                if ok(mid):
                    hi2 = mid
                else:
                    lo2 = mid
            k[i] = hi2
        r = gaussian(running_max(k, 9), 3)
        for i in range(n):
            kk = max(r[i], k[i])
            z[i] *= kk
            if i in used_set:
                if kfit[i] > 1.001:
                    limited += 1
                if kk > kfit[i] * 1.001:
                    zoomed += 1
        anchors = slide_inside()
    shifted = sum(1 for i in used_idx if np.linalg.norm(anchors[i] - p) > 0.5)

    xf = [FrameXform(np.array([ax[i], ay[i]]), np.asarray(anchors[i], dtype=np.float64), float(z[i]), float(psi[i]),
                     bool(track.has_data[i])) for i in range(n)]
    max_up = max((xf[i].z for i in used_idx), default=1.0)
    return CompositionPlan(xf, out_w, out_h, max_up, oob, shifted, zoomed, limited, mirrored)
