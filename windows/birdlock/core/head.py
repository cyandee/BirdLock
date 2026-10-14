"""Head observations, similarity transforms and the Procrustes head template (port of Analysis/HeadModel.swift)."""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from .util import median

# HeadPoint order
BEAK, CROWN, FOREHEAD, EYE, NAPE, THROAT = range(6)
N_POINTS = 6


@dataclass
class HeadObservation:
    points: list            # [ (x, y) | None ] × 6
    conf: list              # [float] × 6

    @staticmethod
    def empty() -> "HeadObservation":
        return HeadObservation([None] * N_POINTS, [0.0] * N_POINTS)

    def __getitem__(self, i):
        return self.points[i]

    @property
    def valid_count(self) -> int:
        return sum(p is not None for p in self.points)

    @staticmethod
    def from_keypoints(kps: list, schema, min_conf: float, eye_side: str | None = None) -> "HeadObservation":
        """kps: [(x, y, conf)] in schema order. eye_side: 'left_eye' / 'right_eye' / None (most confident)."""
        o = HeadObservation.empty()

        def kp(part):
            i = schema.index(part)
            return kps[i] if i is not None and i < len(kps) else None

        def put(hp, k):
            if k is not None and k[2] >= min_conf:
                o.points[hp] = (k[0], k[1])
                o.conf[hp] = k[2]

        put(BEAK, kp("beak"))
        put(CROWN, kp("crown") or kp("head_top"))
        put(FOREHEAD, kp("forehead"))
        put(NAPE, kp("nape"))
        put(THROAT, kp("throat"))
        l, r = kp("left_eye"), kp("right_eye")
        if eye_side:
            put(EYE, l if eye_side == "left_eye" else r)
        else:
            cands = [k for k in (l, r) if k is not None]
            put(EYE, max(cands, key=lambda k: k[2]) if cands else None)
        return o

    def to_dict(self):
        return {"points": [list(p) if p is not None else None for p in self.points], "conf": list(self.conf)}

    @staticmethod
    def from_dict(d):
        return HeadObservation([tuple(p) if p is not None else None for p in d["points"]], list(d["conf"]))


@dataclass
class Similarity:
    """p = t + s · R(theta) · F · q,  F = diag(1, ±1)"""
    t: np.ndarray
    s: float
    theta: float
    reflect: bool

    def apply(self, q) -> np.ndarray:
        q = np.asarray(q, dtype=np.float64)
        f = np.array([q[0], -q[1]]) if self.reflect else q
        c, sn = math.cos(self.theta), math.sin(self.theta)
        return self.t + self.s * np.array([c * f[0] - sn * f[1], sn * f[0] + c * f[1]])

    def inverse(self, p) -> np.ndarray:
        d = (np.asarray(p, dtype=np.float64) - self.t) / self.s
        c, sn = math.cos(-self.theta), math.sin(-self.theta)
        f = np.array([c * d[0] - sn * d[1], sn * d[0] + c * d[1]])
        return np.array([f[0], -f[1]]) if self.reflect else f

    @staticmethod
    def fit(src, dst, w, reflect: bool):
        """Weighted least-squares similarity src -> dst. Returns (sim, rms residual in template units) or None."""
        n = len(src)
        if n < 2:
            return None
        src = np.asarray(src, dtype=np.float64)
        dst = np.asarray(dst, dtype=np.float64)
        w = np.asarray(w, dtype=np.float64)
        srcF = src * np.array([1.0, -1.0]) if reflect else src
        W = w.sum()
        if W <= 0:
            return None
        ms = (w[:, None] * srcF).sum(0) / W
        md = (w[:, None] * dst).sum(0) / W
        q = srcF - ms
        p = dst - md
        a = float((w * (q[:, 0] * p[:, 0] + q[:, 1] * p[:, 1])).sum())
        b = float((w * (q[:, 0] * p[:, 1] - q[:, 1] * p[:, 0])).sum())
        ss = float((w * (q ** 2).sum(1)).sum())
        if ss <= 1e-12:
            return None
        theta = math.atan2(b, a)
        s = math.hypot(a, b) / ss
        if s <= 1e-9:
            return None
        c, sn = math.cos(theta), math.sin(theta)
        t = md - s * np.array([c * ms[0] - sn * ms[1], sn * ms[0] + c * ms[1]])
        sim = Similarity(t, s, theta, reflect)
        err = sum(w[i] * float(((sim.apply(src[i]) - dst[i]) ** 2).sum()) for i in range(n))
        return sim, math.sqrt(err / W) / s


@dataclass
class HeadTemplate:
    points: list   # [np.array(2) | None] × 6, normalised (centroid 0, RMS radius 1, beak → +x)

    def __getitem__(self, i):
        return self.points[i]

    @property
    def head_center(self) -> np.ndarray:
        ps = [self.points[k] for k in (CROWN, FOREHEAD, EYE, NAPE, THROAT) if self.points[k] is not None]
        return np.mean(ps, axis=0) if ps else np.zeros(2)

    @property
    def head_length(self) -> float:
        b, n, e = self.points[BEAK], self.points[NAPE], self.points[EYE]
        if b is not None and n is not None:
            return float(np.linalg.norm(b - n))
        if b is not None and e is not None:
            return float(np.linalg.norm(b - e)) * 1.8
        return 2.0

    @staticmethod
    def estimate(obs: list[HeadObservation], iterations: int = 4) -> "HeadTemplate | None":
        best, seed = -1.0, -1
        for i, o in enumerate(obs):
            sc = o.valid_count + (0.5 if o[BEAK] is not None else 0) + (0.5 if o[EYE] is not None else 0) + sum(o.conf) * 0.01
            if sc > best:
                best, seed = sc, i
        if seed < 0 or obs[seed].valid_count < 3:
            return None
        tmpl = HeadTemplate([np.array(p, dtype=np.float64) if p is not None else None for p in obs[seed].points])
        tmpl._normalise()
        for _ in range(iterations):
            acc = [[] for _ in range(N_POINTS)]
            for o in obs:
                r = tmpl.fit(o)
                if r is None or r[1] >= 0.5:
                    continue
                sim = r[0]
                for k in range(N_POINTS):
                    if o.points[k] is not None:
                        acc[k].append(sim.inverse(o.points[k]))
            new = [None] * N_POINTS
            for k in range(N_POINTS):
                if len(acc[k]) >= 2:
                    a = np.array(acc[k])
                    new[k] = np.array([median(a[:, 0]), median(a[:, 1])])
            if sum(p is not None for p in new) < 3:
                break
            tmpl.points = new
            tmpl._normalise()
        return tmpl

    def _normalise(self):
        ps = [p for p in self.points if p is not None]
        if len(ps) < 2:
            return
        c = np.mean(ps, axis=0)
        r = math.sqrt(np.mean([float(((p - c) ** 2).sum()) for p in ps]))
        if r <= 1e-9:
            return
        ang = 0.0
        if self.points[BEAK] is not None:
            d = self.points[BEAK] - c
            ang = math.atan2(d[1], d[0])
        cs, sn = math.cos(-ang), math.sin(-ang)

        def tr(p):
            q = (p - c) / r
            return np.array([cs * q[0] - sn * q[1], sn * q[0] + cs * q[1]])

        self.points = [tr(p) if p is not None else None for p in self.points]
        cr = self.points[CROWN] if self.points[CROWN] is not None else self.points[FOREHEAD]
        if cr is not None and cr[1] > 0:
            self.points = [np.array([p[0], -p[1]]) if p is not None else None for p in self.points]

    def fit(self, o: HeadObservation, prefer_reflect: bool | None = None):
        src, dst, w = [], [], []
        for k in range(N_POINTS):
            if self.points[k] is not None and o.points[k] is not None:
                src.append(self.points[k]); dst.append(o.points[k]); w.append(max(0.05, o.conf[k]))
        if len(src) < 2:
            return None
        if len(src) == 2:
            return Similarity.fit(src, dst, w, bool(prefer_reflect))
        a = Similarity.fit(src, dst, w, False)
        b = Similarity.fit(src, dst, w, True)
        if b is None:
            return a
        if a is None:
            return b
        return b if b[1] < a[1] * 0.8 else a

    def to_dict(self):
        return {"points": [p.tolist() if p is not None else None for p in self.points]}
