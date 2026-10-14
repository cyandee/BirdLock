"""Small numeric helpers (port of Util/Math.swift). NaN marks a missing value throughout."""
from __future__ import annotations

import math

import numpy as np


def clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def rot(v: np.ndarray, a: float) -> np.ndarray:
    """Rotate 2-vector(s) by angle a (radians)."""
    c, s = math.cos(a), math.sin(a)
    v = np.asarray(v, dtype=np.float64)
    return np.stack([c * v[..., 0] - s * v[..., 1], s * v[..., 0] + c * v[..., 1]], axis=-1)


def median(xs) -> float | None:
    a = np.asarray(xs, dtype=np.float64)
    a = a[np.isfinite(a)]
    return float(np.median(a)) if a.size else None


def percentile(xs, p: float) -> float | None:
    a = np.asarray(xs, dtype=np.float64)
    a = a[np.isfinite(a)]
    return float(np.percentile(a, clamp(p, 0, 1) * 100)) if a.size else None


def fill_gaps(x) -> np.ndarray:
    """Linear interpolation over NaN gaps; edges held constant."""
    x = np.asarray(x, dtype=np.float64).copy()
    ok = np.isfinite(x)
    if not ok.any():
        return x
    idx = np.arange(len(x))
    x[~ok] = np.interp(idx[~ok], idx[ok], x[ok])
    return x


def gaussian(x, sigma: float, weights=None) -> np.ndarray:
    """NaN-aware Gaussian smoothing with normalised weights (sigma in samples)."""
    x = np.asarray(x, dtype=np.float64)
    n = len(x)
    if n == 0 or sigma <= 0.01:
        return x.copy()
    r = max(1, int(math.ceil(sigma * 3)))
    k = np.exp(-0.5 * (np.arange(-r, r + 1) ** 2) / (sigma * sigma))
    ok = np.isfinite(x)
    w = ok.astype(np.float64) * (np.asarray(weights, dtype=np.float64) if weights is not None else 1.0)
    xv = np.where(ok, x, 0.0) * w
    num = np.convolve(xv, k, mode="same") if n >= len(k) else _conv_small(xv, k)
    den = np.convolve(w, k, mode="same") if n >= len(k) else _conv_small(w, k)
    out = np.full(n, np.nan)
    good = den > 1e-12
    out[good] = num[good] / den[good]
    return out


def _conv_small(x, k):
    r = len(k) // 2
    n = len(x)
    out = np.zeros(n)
    for i in range(n):
        lo, hi = max(0, i - r), min(n - 1, i + r)
        out[i] = np.dot(x[lo:hi + 1], k[lo - i + r:hi - i + r + 1])
    return out


def running_median(x, radius: int) -> np.ndarray:
    x = np.asarray(x, dtype=np.float64)
    if radius <= 0:
        return x.copy()
    n = len(x)
    out = np.full(n, np.nan)
    for i in range(n):
        seg = x[max(0, i - radius):min(n, i + radius + 1)]
        seg = seg[np.isfinite(seg)]
        if seg.size:
            out[i] = np.median(seg)
    return out


def running_max(x, radius: int) -> np.ndarray:
    x = np.asarray(x, dtype=np.float64)
    n = len(x)
    return np.array([np.max(x[max(0, i - radius):min(n, i + radius + 1)]) for i in range(n)]) if n else x


def unwrap_angles(a) -> np.ndarray:
    a = np.asarray(a, dtype=np.float64).copy()
    last = None
    for i in range(len(a)):
        if not math.isfinite(a[i]):
            continue
        if last is not None:
            v = a[i]
            while v - last > math.pi:
                v -= 2 * math.pi
            while v - last < -math.pi:
                v += 2 * math.pi
            a[i] = v
        last = a[i]
    return a


def decode_scale(needed: float) -> float:
    """Largest power-of-two reduction (1, 1/2, 1/4, 1/8) giving at least `needed` pixels per original pixel.
    JPEG decodes at these scales directly in the DCT domain (much faster, much less memory)."""
    s = 1.0
    while s > 0.125 + 1e-9 and s / 2 >= needed:
        s /= 2
    return s
