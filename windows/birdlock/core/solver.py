"""Trajectory fusion (port of Analysis/TrajectorySolver.swift).

Fuses absolute per-frame measurements (noisy keypoints) with relative inter-frame displacements (precise
sub-pixel registration) by robust least squares:

    minimise  Σ w_i |x_i − m_i|²  +  Σ λ_i |x_i − x_{i−1} − r_i|²

solved per axis with a tridiagonal (Thomas) solver; weights re-estimated jointly in 2-D (Huber for
measurements, redescending Cauchy for links).
"""
from __future__ import annotations

import numpy as np

from .util import fill_gaps


def solve(meas_xy, meas_sigma, link_dxy, link_sigma, cauchy_k=3.0, iterations=12):
    """
    meas_xy: (n, 2) with NaN rows for missing; meas_sigma: (n,)
    link_dxy: (n, 2) with NaN rows for missing (row i = x_i − x_{i−1}, row 0 ignored); link_sigma: (n,)
    Returns (positions (n, 2), measurement_inlier (n,), link_inlier (n,)).
    """
    m = np.asarray(meas_xy, dtype=np.float64)
    ms = np.asarray(meas_sigma, dtype=np.float64)
    r = np.asarray(link_dxy, dtype=np.float64)
    ls = np.asarray(link_sigma, dtype=np.float64)
    n = len(m)
    if n == 0:
        return np.zeros((0, 2)), np.zeros(0, bool), np.zeros(0, bool)
    has_m = np.isfinite(m).all(1)
    w0 = np.where(has_m, 1 / np.maximum(1e-6, ms * ms), 0.0)
    has_l = np.isfinite(r).all(1)
    has_l[0] = False
    l0 = np.where(has_l, 1 / np.maximum(1e-6, ls * ls), 0.0)
    if not (w0 > 0).any():
        return np.zeros((n, 2)), np.zeros(n, bool), np.zeros(n, bool)
    filled = np.stack([fill_gaps(m[:, 0]), fill_gaps(m[:, 1])], 1)
    min_w = w0[w0 > 0].min() * 1e-6
    w0 = np.where(w0 > 0, w0, min_w)
    mx = np.where(has_m[:, None], m, filled)
    rr = np.where(has_l[:, None], r, 0.0)

    w, l = w0.copy(), l0.copy()
    m_in = np.ones(n, bool)
    l_in = np.ones(n, bool)
    x = mx.copy()
    for _ in range(iterations):
        x = np.stack([_thomas(w, l, mx[:, 0], rr[:, 0]), _thomas(w, l, mx[:, 1], rr[:, 1])], 1)
        # measurements: Huber (bounded influence, never fully rejected)
        e = np.linalg.norm(x - mx, axis=1)
        k = 1.5 * ms
        real = w0 > min_w
        w = np.where(real, np.where(e <= k, w0, w0 * k / np.maximum(e, 1e-12)), w0)
        m_in = np.where(real, e <= 3 * ms, m_in)
        # links: Cauchy (a failed registration loses all influence)
        d = np.zeros((n, 2))
        d[1:] = x[1:] - x[:-1] - rr[1:]
        e = np.linalg.norm(d, axis=1)
        u = e / (cauchy_k * np.maximum(ls, 1e-12))
        l = np.where(l0 > 0, l0 / (1 + u * u), 0.0)
        l_in = np.where(l0 > 0, e <= 3 * ls, l_in)
    return x, m_in, l_in


def _thomas(w, l, m, r):
    n = len(w)
    a = np.zeros(n); b = np.zeros(n); c = np.zeros(n); d = np.zeros(n)
    b[:] = w
    d[:] = w * m
    b[1:] += l[1:]; a[1:] = -l[1:]; d[1:] += l[1:] * r[1:]
    b[:-1] += l[1:]; c[:-1] = -l[1:]; d[:-1] -= l[1:] * r[1:]
    cp = np.zeros(n); dp = np.zeros(n)
    cp[0] = c[0] / b[0]; dp[0] = d[0] / b[0]
    for i in range(1, n):
        den = b[i] - a[i] * cp[i - 1]
        cp[i] = c[i] / den
        dp[i] = (d[i] - a[i] * dp[i - 1]) / den
    x = np.zeros(n)
    x[-1] = dp[-1]
    for i in range(n - 2, -1, -1):
        x[i] = dp[i] - cp[i] * x[i + 1]
    return x
