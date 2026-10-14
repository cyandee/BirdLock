"""Sub-pixel registration by windowed phase correlation (port of Analysis/PhaseCorrelation.swift).

Gaussian-shaped correlation peak (frequency-domain low-pass), log-parabolic peak interpolation and
iterative re-centring (the second patch is Fourier-shifted by the current estimate before windowing),
which removes the window bias. Accuracy ≈ 0.05 px.
"""
from __future__ import annotations

import math

import numpy as np


class PhaseCorrelator:
    def __init__(self, size: int, peak_sigma: float = 1.1):
        assert size > 0 and size & (size - 1) == 0, "size must be a power of two"
        self.n = n = size
        k = np.array([i if i <= n // 2 else i - n for i in range(n)], dtype=np.float64)
        self.kx = k
        a = 2 * math.pi * peak_sigma / n
        self.lowpass = np.exp(-0.5 * (k[None, :] ** 2 + k[:, None] ** 2) * a * a)
        self.set_gaussian_window(n / 5)

    def set_gaussian_window(self, sigma: float):
        n = self.n
        c = (n - 1) / 2
        x = np.arange(n)
        g = np.exp(-0.5 * ((x[None, :] - c) ** 2 + (x[:, None] - c) ** 2) / (sigma * sigma))
        h = 0.5 - 0.5 * np.cos(2 * math.pi * x / (n - 1))
        self.window = g * np.sqrt(h[None, :] * h[:, None])

    def _forward(self, img):
        w = self.window
        mean = (img * w).sum() / w.sum()
        return np.fft.fft2((img - mean) * w)

    def _fourier_shift(self, img, d):
        """b'(x) = b(x + d)"""
        ph = 2 * math.pi / self.n * (self.kx[None, :] * d[0] + self.kx[:, None] * d[1])
        return np.fft.ifft2(np.fft.fft2(img) * np.exp(1j * ph)).real

    def _peak(self, A, B):
        n = self.n
        X = np.conj(A) * B
        R = np.fft.ifft2(X * (self.lowpass / (np.abs(X) + 1e-9))).real
        py, px = np.unravel_index(int(np.argmax(R)), R.shape)

        def at(x, y):
            return float(R[y % n, x % n])

        def sub(l, c, r):
            L, C, Rr = math.log(max(l, 1e-9)), math.log(max(c, 1e-9)), math.log(max(r, 1e-9))
            d = L - 2 * C + Rr
            return 0.0 if abs(d) < 1e-12 else max(-0.5, min(0.5, 0.5 * (L - Rr) / d))

        c0 = at(px, py)
        sx = px + sub(at(px - 1, py), c0, at(px + 1, py))
        sy = py + sub(at(px, py - 1), c0, at(px, py + 1))
        if sx > n / 2:
            sx -= n
        if sy > n / 2:
            sy -= n
        # peak-to-sidelobe ratio outside a small neighbourhood
        yy = np.abs(np.arange(n) - py); yy = np.minimum(yy, n - yy)
        xx = np.abs(np.arange(n) - px); xx = np.minimum(xx, n - xx)
        mask = ~((yy[:, None] <= 4) & (xx[None, :] <= 4))
        side = R[mask]
        sd = max(1e-12, float(side.std()))
        return np.array([sx, sy]), (c0 - float(side.mean())) / sd

    def correlate(self, a: np.ndarray, b: np.ndarray, iterations: int = 3):
        """Returns (shift, quality): content moved by `shift` from a to b. None if sizes mismatch."""
        n = self.n
        if a.shape != (n, n) or b.shape != (n, n):
            return None
        A = self._forward(a)
        d = np.zeros(2)
        q = 0.0
        for it in range(iterations + 1):
            bb = b if it == 0 else self._fourier_shift(b, d)
            s, qq = self._peak(A, self._forward(bb))
            d = d + s
            if it == 0:
                q = qq
            if np.linalg.norm(s) < 0.005 or np.linalg.norm(d) > n / 3:
                break
        return d, q


def extract_exact(img: np.ndarray, x0: int, y0: int, n: int, factor: int) -> np.ndarray:
    """Copy the integer-aligned square (x0, y0, n·f, n·f) of a gray image 1:1 and box-average f×f blocks.
    Out-of-image areas are filled with the mean of the valid region. Returns float32 in 0…1."""
    side = n * factor
    H, W = img.shape[:2]
    buf = np.zeros((side, side), np.float32)
    valid = np.zeros((side, side), bool)
    sx0, sy0 = max(0, x0), max(0, y0)
    sx1, sy1 = min(W, x0 + side), min(H, y0 + side)
    if sx1 > sx0 and sy1 > sy0:
        buf[sy0 - y0:sy1 - y0, sx0 - x0:sx1 - x0] = img[sy0:sy1, sx0:sx1]
        valid[sy0 - y0:sy1 - y0, sx0 - x0:sx1 - x0] = True
    fill = float(buf[valid].mean()) if valid.any() else 127.5
    buf[~valid] = fill
    out = buf.reshape(n, factor, n, factor).mean(axis=(1, 3))
    return out / 255.0


def sharpness(p: np.ndarray) -> float:
    """Normalised Laplacian energy var(Laplacian) / var(I): exposure-invariant, higher = sharper."""
    if p.shape[0] <= 4 or p.shape[1] <= 4:
        return 0.0
    c = p[1:-1, 1:-1]
    lap = p[1:-1, :-2] + p[1:-1, 2:] + p[:-2, 1:-1] + p[2:, 1:-1] - 4 * c
    return float(lap.var() / max(1e-6, c.var()))
