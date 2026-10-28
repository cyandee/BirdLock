"""Preview area: output preview (with draggable watermark) and the source view (detections, crop editing,
eye correction, zoom that follows the head). Port of Views/PreviewArea.swift."""
from __future__ import annotations

import math
import time

import numpy as np
from PySide6.QtCore import QPointF, QRectF, QSize, Qt, QTimer
from PySide6.QtGui import QBrush, QColor, QCursor, QFont, QPainter, QPainterPath, QPen, QPolygonF
from PySide6.QtWidgets import (QFrame, QHBoxLayout, QLabel, QProgressBar, QPushButton, QSizePolicy, QVBoxLayout,
                               QWidget)

from . import theme
from ..core.analysis import STAGES


def fit_rect(w: float, h: float, bounds: QRectF) -> QRectF:
    if w <= 0 or h <= 0:
        return QRectF()
    s = min(bounds.width() / w, bounds.height() / h)
    return QRectF(bounds.center().x() - w * s / 2, bounds.center().y() - h * s / 2, w * s, h * s)


class Mapping:
    """source px <-> widget points for the (possibly zoomed) source view."""

    def __init__(self, s: float, ox: float, oy: float, w: int, h: int):
        self.s, self.ox, self.oy, self.w, self.h = s, ox, oy, w, h

    def view(self, v) -> QPointF:
        return QPointF(self.ox + v[0] * self.s, self.oy + v[1] * self.s)

    def src(self, p: QPointF) -> np.ndarray:
        return np.array([(p.x() - self.ox) / self.s, (p.y() - self.oy) / self.s])

    def rect(self, x, y, w, h) -> QRectF:
        return QRectF(self.ox + x * self.s, self.oy + y * self.s, w * self.s, h * self.s)

    @property
    def image_rect(self) -> QRectF:
        return self.rect(0, 0, self.w, self.h)


def _point_in_quad(p: QPointF, q: list[QPointF]) -> bool:
    return QPolygonF(q).containsPoint(p, Qt.OddEvenFill)


class Pill(QLabel):
    def __init__(self, text: str, color: QColor):
        super().__init__(text)
        self.setStyleSheet(f"QLabel {{ background: rgba(18,19,22,0.82); color: {theme.hexa(color)};"
                           f" border: 1px solid {theme.hexa(color, 0.55)}; border-radius: 10px; padding: 2px 9px;"
                           " font-size: 12px; font-weight: 500; }")


class PreviewCanvas(QWidget):
    def __init__(self, state, parent=None):
        super().__init__(parent)
        self.state = state
        self.setMouseTracking(True)
        self.setAcceptDrops(False)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self._drag = None            # dict describing the active drag
        self._hover = None
        self._zoom_center = None     # (frame, zoom, center)
        self._wm_drag = None
        self._wm_hover = False
        self._detail_timer = QTimer(self, singleShot=True, interval=140, timeout=self._request_detail)
        self._detail_key = None
        self.setAttribute(Qt.WA_OpaquePaintEvent)     # we fill the whole rect: skip the erase step (less flicker)
        self.setAttribute(Qt.WA_NoSystemBackground)
        state.changed.connect(self._on_changed)

    def _on_changed(self, topic):
        if topic in ("preview", "source", "job", "analysis", "frame", "view", "tool", "zoom", "watermark", "settings",
                     "playing", "phase"):
            if topic in ("frame", "view", "zoom", "job") and self.state.view_mode == "source":
                self._schedule_detail()
            self.update()

    # ---------------------------------------------------------------- geometry

    def bounds(self) -> QRectF:
        return QRectF(self.rect()).adjusted(20, 18, -20, -18)

    def output_rect(self) -> QRectF:
        W, H = self.state.export.output_size
        return fit_rect(W, H, self.bounds())

    def mapping(self) -> Mapping | None:
        a = self.state.analysis
        i = self.state.current_frame
        if a is None or not 0 <= i < a.count:
            return None
        f = a.frames[i]
        b = self.bounds()
        fit = fit_rect(f.pixelWidth, f.pixelHeight, b)
        k = fit.width() / f.pixelWidth
        z = max(1.0, self.state.source_zoom)
        if z <= 1.01:
            return Mapping(k, fit.x(), fit.y(), f.pixelWidth, f.pixelHeight)
        s = k * z
        zc = self._zoom_center
        if zc and zc[0] == i and zc[1] == z:
            c = np.array(zc[2])
        else:
            c = a.track.head_center[i].copy() if a.track is not None else np.array([f.pixelWidth / 2, f.pixelHeight / 2])
            self._zoom_center = (i, z, c.copy())
        hw, hh = b.width() / (2 * s), b.height() / (2 * s)
        c[0] = min(max(c[0], hw), f.pixelWidth - hw) if f.pixelWidth > 2 * hw else f.pixelWidth / 2
        c[1] = min(max(c[1], hh), f.pixelHeight - hh) if f.pixelHeight > 2 * hh else f.pixelHeight / 2
        return Mapping(s, b.center().x() - c[0] * s, b.center().y() - c[1] * s, f.pixelWidth, f.pixelHeight)

    def crop_quad(self, i: int) -> list[np.ndarray] | None:
        job = self.state.job
        if job is None or not job.contains(i):
            return None
        W, H = job.output_size
        return job.plan.xforms[i].source_quad(W, H)

    def _eye_radius(self, i, m: Mapping) -> float:
        t = self.state.analysis.track
        return max(7.0, t.head_length[i] * m.s * 0.12)

    def _schedule_detail(self):
        if self.state.source_zoom > 1.01:
            self._detail_timer.start()

    def _request_detail(self):
        m = self.mapping()
        if m is None:
            return
        b = self.bounds()
        vis = (( b.x() - m.ox) / m.s, (b.y() - m.oy) / m.s, b.width() / m.s, b.height() / m.s)
        pad_x, pad_y = vis[2] * 0.1, vis[3] * 0.1
        region = (vis[0] - pad_x, vis[1] - pad_y, vis[2] + 2 * pad_x, vis[3] + 2 * pad_y)
        dpr = self.devicePixelRatioF()
        self.state.request_source_detail(region, region[2] * m.s * dpr)

    # ---------------------------------------------------------------- painting

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.setRenderHint(QPainter.SmoothPixmapTransform)
        p.fillRect(self.rect(), theme.CANVAS)
        if self.state.analysis is None:
            return
        if self.state.view_mode == "output":
            self._paint_output(p)
        else:
            self._paint_source(p)

    def _paint_output(self, p: QPainter):
        st = self.state
        r = self.output_rect()
        p.fillRect(r, QColor(0, 0, 0))
        if st.preview_image is not None:
            p.drawImage(r, st.preview_image)
        job = st.job
        W, H = st.export.output_size
        if not st.playing and not st.export.focusMark.enabled and job and job.contains(st.current_frame):
            a = job.plan.xforms[st.current_frame].p
            x, y = r.x() + a[0] / W * r.width(), r.y() + a[1] / H * r.height()
            p.setPen(QPen(QColor(64, 217, 255, 140), 1))
            for (x0, y0, x1, y1) in ((x, y - 13, x, y - 4), (x, y + 4, x, y + 13), (x - 13, y, x - 4, y), (x + 4, y, x + 13, y)):
                p.drawLine(QPointF(x0, y0), QPointF(x1, y1))
        wr = self._watermark_rect()
        if wr is not None:
            p.setOpacity(st.watermark.opacity)
            p.drawImage(wr, st.watermark_qimage)
            p.setOpacity(1.0)
            if not st.playing and (self._wm_hover or self._wm_drag):
                p.setPen(QPen(theme.ACCENT, 1, Qt.DashLine))
                p.setBrush(Qt.NoBrush)
                p.drawRect(wr.adjusted(-4, -4, 4, 4))
                p.setPen(QPen(QColor(0, 0, 0, 120), 1))
                p.setBrush(theme.ACCENT)
                p.drawEllipse(QPointF(wr.right() + 4, wr.bottom() + 4), 5, 5)

    def _watermark_rect(self) -> QRectF | None:
        st = self.state
        if not st.watermark.active or st.watermark_qimage is None:
            return None
        r = self.output_rect()
        wm = st.watermark.copy()
        if self._wm_drag:
            wm.centerX, wm.centerY, wm.size = self._wm_drag["cx"], self._wm_drag["cy"], self._wm_drag["size"]
        x, y, w, h = wm.rect(st.watermark_qimage.width(), st.watermark_qimage.height(), r.width(), r.height())
        return QRectF(r.x() + x, r.y() + y, w, h)

    def _paint_source(self, p: QPainter):
        st = self.state
        a = st.analysis
        m = self.mapping()
        if m is None:
            return
        i = st.current_frame
        ir = m.image_rect
        p.save()
        p.setClipRect(QRectF(self.rect()))
        if st.source_image is not None:
            p.drawImage(ir, st.source_image)
        else:
            p.fillRect(ir, QColor(0, 0, 0))
        if st.source_detail and st.source_detail[2] == i:
            q, (x, y, w, h), _ = st.source_detail
            p.drawImage(m.rect(x, y, w, h), q)
        fa = a.perFrame[i]
        # birds
        for j, b in enumerate(fa.birds):
            rr = m.rect(b.x, b.y, b.w, b.h)
            if j == fa.target:
                p.setPen(QPen(QColor(92, 199, 120, 205), 1.2))
            else:
                p.setPen(QPen(QColor(255, 220, 0, 150), 1, Qt.DashLine))
            p.setBrush(Qt.NoBrush)
            p.drawRoundedRect(rr, 4, 4)
        # crop (or the ghost while dragging), outside dimmed
        quad = self._drag["ghost"] if self._drag and self._drag.get("ghost") is not None else self.crop_quad(i)
        if quad is not None:
            vq = [m.view(v) for v in quad]
            path = QPainterPath()
            path.addRect(ir)
            qp = QPainterPath()
            qp.addPolygon(QPolygonF(vq + [vq[0]]))
            p.fillPath(path.subtracted(qp), QColor(0, 0, 0, 90))
            dragging = self._drag and self._drag.get("ghost") is not None
            p.setPen(QPen(theme.ACCENT if dragging else QColor(255, 255, 255, 215), 1.2, Qt.DashLine))
            p.setBrush(Qt.NoBrush)
            p.drawPolygon(QPolygonF(vq))
            if st.source_tool == "none":
                p.setPen(QPen(QColor(0, 0, 0, 130), 1))
                p.setBrush(QColor(255, 255, 255))
                for c in vq:
                    p.drawRect(QRectF(c.x() - 4.5, c.y() - 4.5, 9, 9))
        # keypoints
        p.setPen(Qt.NoPen)
        for (x, y, cf) in fa.keypoints:
            if cf > 0.2:
                c = QColor(theme.BAD)
                c.setAlphaF(min(1.0, cf + 0.2))
                p.setBrush(c)
                p.drawEllipse(m.view((x, y)), 2.5, 2.5)
        t = a.track
        if t is not None:
            hc = m.view(t.head_center[i])
            p.setPen(QPen(QColor(250, 184, 61, 205), 1))
            p.setBrush(Qt.NoBrush)
            p.drawRect(QRectF(hc.x() - 5, hc.y() - 5, 10, 10))
            lo = max(0, i - 20)
            if i > lo:
                p.setPen(QPen(QColor(64, 217, 255, 90), 1))
                pts = [m.view(t.eye[j]) for j in range(lo, i + 1)]
                p.drawPolyline(QPolygonF(pts))
            rr = self._eye_radius(i, m)
            manual = i in a.manualEye
            color = theme.MANUAL if manual else (theme.EYE if t.eye_visible[i] else theme.WARN)
            e = m.view(t.eye[i])
            ghost = self._drag.get("eye") if self._drag else None
            if ghost is not None:
                faded = QColor(color)
                faded.setAlphaF(0.3)
                p.setPen(QPen(faded, 1))
                p.drawEllipse(e, rr, rr)
                g = m.view(ghost)
                p.setPen(QPen(theme.MANUAL, 2))
                p.drawEllipse(g, rr, rr)
            else:
                p.setPen(QPen(color, 1.6))
                p.drawEllipse(e, rr, rr)
                p.setPen(Qt.NoPen)
                p.setBrush(color)
                p.drawEllipse(e, 1.5, 1.5)
        # tool cursor ring
        if st.source_tool != "none" and self._hover is not None and not self._drag and ir.contains(self._hover):
            p.setPen(QPen(theme.MANUAL if st.source_tool == "fixEye" else theme.ACCENT, 1.5))
            p.setBrush(Qt.NoBrush)
            p.drawEllipse(self._hover, 11, 11)
        p.restore()

    # ---------------------------------------------------------------- interaction (source view)

    def _hit(self, pos: QPointF, m: Mapping):
        st = self.state
        i = st.current_frame
        t = st.analysis.track
        if t is not None:
            e = m.view(t.eye[i])
            if math.hypot(pos.x() - e.x(), pos.y() - e.y()) < max(10, self._eye_radius(i, m) + 3):
                return "eye", None
        q = self.crop_quad(i)
        if q is None:
            return None, None
        vq = [m.view(v) for v in q]
        for k, c in enumerate(vq):
            if math.hypot(pos.x() - c.x(), pos.y() - c.y()) < 11:
                return "corner", k
        return ("inside", None) if _point_in_quad(pos, vq) else (None, None)

    def _update_cursor(self, pos: QPointF):
        st = self.state
        if st.view_mode == "output":
            wr = self._watermark_rect()
            hov = wr is not None and wr.adjusted(-10, -10, 10, 10).contains(pos) and not st.playing
            if hov != self._wm_hover:
                self._wm_hover = hov
                self.update()
            self.setCursor(Qt.OpenHandCursor if hov else Qt.ArrowCursor)
            return
        m = self.mapping()
        if m is None or self._drag:
            return
        if st.source_tool in ("fixEye", "pickBird"):
            self.setCursor(Qt.CrossCursor)
            return
        kind, _ = self._hit(pos, m)
        self.setCursor({"eye": Qt.PointingHandCursor, "corner": Qt.SizeFDiagCursor, "inside": Qt.OpenHandCursor}.get(kind, Qt.ArrowCursor))

    def mousePressEvent(self, ev):
        if ev.button() != Qt.LeftButton:
            return
        st = self.state
        pos = ev.position()
        if st.view_mode == "output":
            wr = self._watermark_rect()
            if wr is not None and wr.adjusted(-10, -10, 10, 10).contains(pos) and not st.playing:
                near = math.hypot(pos.x() - (wr.right() + 4), pos.y() - (wr.bottom() + 4)) < 14
                self._wm_drag = {"start": pos, "cx": st.watermark.centerX, "cy": st.watermark.centerY,
                                 "size": st.watermark.size, "resize": near}
                self.setCursor(Qt.ClosedHandCursor)
            return
        m = self.mapping()
        if m is None:
            return
        start = m.src(pos)
        if st.source_tool == "pickBird":
            self._drag = {"kind": "pick", "start": start}
        elif st.source_tool == "fixEye":
            self._drag = {"kind": "place", "start": start, "eye": start}
        else:
            kind, _ = self._hit(pos, m)
            q = self.crop_quad(st.current_frame)
            if kind == "eye":
                self._drag = {"kind": "eye", "start": start, "eye": start}
            elif kind == "corner" and q is not None:
                c = np.mean(q, axis=0)
                self._drag = {"kind": "scale", "start": start, "quad": q, "center": c, "ghost": None}
                st.begin_crop_edit()
            elif kind == "inside" and q is not None:
                self._drag = {"kind": "move", "start": start, "quad": q, "ghost": None}
                st.begin_crop_edit()
                self.setCursor(Qt.ClosedHandCursor)
        self.update()

    def mouseMoveEvent(self, ev):
        pos = ev.position()
        self._hover = pos
        st = self.state
        if self._wm_drag is not None:
            d = self._wm_drag
            r = self.output_rect()
            if d["resize"]:
                wm = st.watermark
                c = QPointF(r.x() + wm.centerX * r.width(), r.y() + wm.centerY * r.height())
                r0 = math.hypot(d["start"].x() - c.x(), d["start"].y() - c.y())
                r1 = math.hypot(pos.x() - c.x(), pos.y() - c.y())
                d["size"] = min(1.5, max(0.03, wm.size * r1 / max(1.0, r0)))
            else:
                x = st.watermark.centerX + (pos.x() - d["start"].x()) / r.width()
                y = st.watermark.centerY + (pos.y() - d["start"].y()) / r.height()
                if abs(x - 0.5) < 0.012:
                    x = 0.5
                if abs(y - 0.5) < 0.012:
                    y = 0.5
                d["cx"], d["cy"] = min(1, max(0, x)), min(1, max(0, y))
            self.update()
            return
        if not self._drag:
            self._update_cursor(pos)
            if st.source_tool != "none":
                self.update()
            return
        m = self.mapping()
        if m is None:
            return
        cur = m.src(pos)
        d = self._drag
        if d["kind"] in ("eye", "place"):
            d["eye"] = cur
        elif d["kind"] == "move":
            delta = cur - d["start"]
            d["ghost"] = [v + delta for v in d["quad"]]
            st.move_crop(delta)
        elif d["kind"] == "scale":
            c = d["center"]
            r = np.linalg.norm(cur - c) / max(1.0, np.linalg.norm(d["start"] - c))
            d["ghost"] = [c + (v - c) * r for v in d["quad"]]
            st.scale_crop(r)
        self.update()

    def mouseReleaseEvent(self, ev):
        st = self.state
        if self._wm_drag is not None:
            d = self._wm_drag
            st.watermark.centerX, st.watermark.centerY, st.watermark.size = d["cx"], d["cy"], d["size"]
            self._wm_drag = None
            st.watermark_changed()
            self._update_cursor(ev.position())
            return
        d = self._drag
        self._drag = None
        if d:
            m = self.mapping()
            if m is not None:
                p = m.src(ev.position())
                inside = m.image_rect.contains(ev.position())
                if d["kind"] in ("eye", "place") and inside:
                    st.set_manual_eye(p)
                elif d["kind"] == "pick" and inside:
                    st.pick_bird(p)
            if d["kind"] in ("move", "scale"):
                st.end_crop_edit()
        self._update_cursor(ev.position())
        self.update()

    def leaveEvent(self, _):
        self._hover = None
        if self._wm_hover:
            self._wm_hover = False
        self.update()

    def wheelEvent(self, ev):
        st = self.state
        if st.view_mode != "source" or st.analysis is None:
            return
        steps = ev.angleDelta().y() / 120
        z = st.source_zoom * (1.25 ** steps)
        st.source_zoom = 1.0 if z < 1.3 else min(12.0, z)
        st.changed.emit("zoom")


# -------------------------------------------------------------------------------------------- overlays


class SourceToolBar(QFrame):
    def __init__(self, state, parent=None):
        super().__init__(parent)
        self.state = state
        self.setObjectName("toolbar")
        self.setStyleSheet("QFrame#toolbar { background: rgba(30,31,34,0.88); border-radius: 9px; }"
                           "QPushButton { padding: 3px 8px; font-size: 12px; }")
        lay = QHBoxLayout(self)
        lay.setContentsMargins(6, 5, 6, 5)
        lay.setSpacing(5)
        self.fix = QPushButton("◎ 修正鸟眼", checkable=True)
        self.fix.setToolTip("点击（或拖动）到鸟眼的准确位置。本帧作为强约束，前后帧自动重新计算（E）")
        self.pick = QPushButton("☝ 选择目标鸟", checkable=True)
        self.pick.setToolTip("画面里有多只鸟时，点击要跟踪的那只（会重新识别）")
        self.fix.clicked.connect(lambda: self._tool("fixEye"))
        self.pick.clicked.connect(lambda: self._tool("pickBird"))
        lay.addWidget(self.fix)
        lay.addWidget(self.pick)
        self.zoom_btns = []
        for label, z in (("全图", 1.0), ("2×", 2.0), ("4×", 4.0), ("8×", 8.0)):
            b = QPushButton(label, checkable=True)
            b.setToolTip("放大查看鸟头（跟随鸟头）。也可以用鼠标滚轮缩放（Z 切换）")
            b.clicked.connect(lambda _=False, z=z: self._zoom(z))
            lay.addWidget(b)
            self.zoom_btns.append((b, z))
        self.prev = QPushButton("‹")
        self.prev.setToolTip("上一个推算帧 [")
        self.pred = QLabel()
        self.pred.setObjectName("warn")
        self.next = QPushButton("›")
        self.next.setToolTip("下一个推算帧 ]")
        self.prev.clicked.connect(lambda: state.jump_to_predicted(-1))
        self.next.clicked.connect(lambda: state.jump_to_predicted(1))
        for w in (self.prev, self.pred, self.next):
            lay.addWidget(w)
        self.undo = QPushButton("↶ 撤销本帧修正")
        self.undo.clicked.connect(lambda: state.clear_manual_eye())
        lay.addWidget(self.undo)
        self._size = QSize()
        state.changed.connect(lambda t: self.refresh() if t in ("view", "tool", "zoom", "analysis", "job", "phase", "frame") else None)
        self.refresh()

    def _tool(self, t):
        self.state.source_tool = "none" if self.state.source_tool == t else t
        self.state.changed.emit("tool")

    def _zoom(self, z):
        self.state.source_zoom = z
        self.state.changed.emit("zoom")

    def refresh(self):
        st = self.state
        vis = st.view_mode == "source" and st.analysis is not None
        self.setVisible(vis)
        if not vis:
            return
        self.fix.setText("◎ 修正机头" if st.is_aircraft else "◎ 修正鸟眼")
        self.fix.setToolTip("点击当前帧机头的准确位置（E）" if st.is_aircraft else "点击鸟眼的准确位置（E）")
        self.pick.setText("☝ 选择飞机" if st.is_aircraft else "☝ 选择目标鸟")
        self.pick.setToolTip("点击要跟踪的主体（会重新识别）")
        self.fix.setChecked(st.source_tool == "fixEye")
        self.pick.setChecked(st.source_tool == "pickBird")
        near = min((z for _, z in self.zoom_btns), key=lambda z: abs(z - st.source_zoom))
        for b, z in self.zoom_btns:
            b.setChecked(z == near)
        p = st.predicted_frames
        for w in (self.prev, self.pred, self.next):
            w.setVisible(bool(p))
        self.pred.setText(f"推算 {len(p)} 帧")
        self.undo.setVisible(st.current_frame in st.analysis.manualEye)
        s = self.sizeHint()
        if s != self._size:            # avoid adjustSize churn while playing
            self._size = s
            self.adjustSize()


class FrameBadges(QWidget):
    def __init__(self, state, parent=None):
        super().__init__(parent)
        self.state = state
        self.lay = QHBoxLayout(self)
        self.lay.setContentsMargins(0, 0, 0, 0)
        self.lay.setSpacing(6)
        # only refresh on topics that can change the badges; per-frame "preview"/"source" updates would
        # rebuild the pills dozens of times a second while playing (flicker)
        state.changed.connect(lambda t: self.refresh() if t in ("job", "frame", "analysis", "phase", "view") else None)
        self.refresh()

    def _add(self, w):
        self.lay.addWidget(w)
        w.show()

    def refresh(self):
        while self.lay.count():
            w = self.lay.takeAt(0).widget()
            if w:
                # hide only: setParent(None) would make the widget a brief top-level window
                # flashing at the top-left corner of the screen
                w.hide()
                w.deleteLater()
        st = self.state
        job, a = st.job, st.analysis
        i = st.current_frame
        if job is None or a is None or a.track is None or not 0 <= i < len(job.status):
            self.hide()
            return
        self.show()
        status = job.status[i]
        labels = {"excluded": "已排除", "blurry": "模糊帧", "untracked": "未识别", "trimmed": "已裁掉"}
        if status != "ok":
            self._add(Pill(labels[status], theme.BAD))
        t = a.track
        if i in a.manualEye:
            self._add(Pill("手动修正", theme.MANUAL))
        elif st.is_aircraft:
            source = a.perFrame[i].aircraft
            self._add(Pill(("机头跟踪" if source is not None and source.source == "tracked" else "机头识别") if t.has_data[i] else "未定位机头",theme.OK if t.has_data[i] else theme.WARN))
            button = QPushButton("修正机头");button.clicked.connect(st.start_fixing_eye);self._add(button)
        elif t.eye_visible[i]:
            self._add(Pill("鸟眼", theme.OK))
        elif t.has_data[i]:
            pill = Pill("鸟头推算", theme.WARN)
            pill.setToolTip("这一帧鸟眼被遮挡，位置是根据鸟头其他部位推算的")
            self._add(pill)
            if not (st.view_mode == "source" and st.source_tool == "fixEye"):
                b = QPushButton("修正")
                b.setStyleSheet(f"QPushButton {{ background: {theme.hexa(theme.MANUAL)}; color: #111; border: none;"
                                f" border-radius: 6px; padding: 3px 10px; font-weight: 600; }}")
                b.setToolTip("切换到原图并放大，点击鸟眼的准确位置（E）")
                b.clicked.connect(st.start_fixing_eye)
                self._add(b)
        elif status == "untracked":
            b = QPushButton("手动标记鸟眼")
            b.setToolTip("这一帧没有识别到鸟。手动标记后这一帧也能用在成片里")
            b.clicked.connect(st.start_fixing_eye)
            self._add(b)
        self.lay.activate()
        self.resize(self.sizeHint())


class HintLabel(QLabel):
    def __init__(self, state, parent=None):
        super().__init__(parent)
        self.state = state
        self.setStyleSheet("QLabel { background: rgba(30,31,34,0.85); color: #aaa; border-radius: 11px; padding: 4px 12px;"
                           " font-size: 12px; }")
        self.setAttribute(Qt.WA_TransparentForMouseEvents)
        self._size = QSize()
        state.changed.connect(lambda t: self.refresh() if t in ("view", "tool", "watermark", "job", "analysis",
                                                                "playing", "phase") else None)
        self.refresh()

    def refresh(self):
        st = self.state
        text = None
        if not st.playing and st.analysis is not None:
            if st.view_mode == "source":
                text = {"fixEye": "在鸟眼的准确位置点击（可按住拖动微调）· 推算不准的帧逐一修正后，前后帧会自动跟着重算",
                        "pickBird": "点击要跟踪的鸟",
                        "none": "拖动虚线框移动取景 · 拖动四角缩放取景范围 · 拖动圆圈修正鸟眼 · 滚轮缩放"}[st.source_tool]
                if st.is_aircraft:
                    text = {"fixEye":"点击当前帧机头的准确位置，可拖动微调","pickBird":"点击要跟踪的飞机",
                            "none":"拖动虚线框移动取景 · 拖动四角缩放 · 拖动圆圈修正当前帧机头"}[st.source_tool]
            elif st.watermark.active and st.watermark_qimage is not None:
                text = "拖动水印调整位置，拖动右下角圆点调整大小"
        self.setVisible(text is not None)
        if text:
            self.setText(text)
            s = self.sizeHint()
            if s != self._size:
                self._size = s
                self.adjustSize()


class StatusCard(QFrame):
    """Floating card for import / analysis / error states (replaces the old full-width bar)."""

    def __init__(self, state, parent=None):
        super().__init__(parent)
        self.state = state
        self.setObjectName("statusCard")
        self.setStyleSheet(f"QFrame#statusCard {{ background: {theme.hexa(theme.PANEL)}; border: 1px solid rgba(255,255,255,0.08);"
                           " border-radius: 16px; }")
        self.setFixedWidth(380)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(24, 22, 24, 20)
        lay.setSpacing(14)
        head = QHBoxLayout()
        icon = QLabel("🐦")
        icon.setStyleSheet(f"QLabel {{ background: {theme.hexa(theme.ACCENT, 0.15)}; border-radius: 23px; font-size: 22px; }}")
        icon.setFixedSize(46, 46)
        icon.setAlignment(Qt.AlignCenter)
        head.addWidget(icon)
        tv = QVBoxLayout()
        tv.setSpacing(2)
        self.title = QLabel()
        self.title.setStyleSheet("font-size: 15px; font-weight: 600;")
        self.sub = QLabel()
        self.sub.setObjectName("caption")
        tv.addWidget(self.title)
        tv.addWidget(self.sub)
        head.addLayout(tv, 1)
        lay.addLayout(head)
        self.steps = []
        for name in [*STAGES, ""]:
            row = QHBoxLayout()
            mark = QLabel("○")
            mark.setFixedWidth(18)
            lbl = QLabel(name)
            pct = QLabel()
            pct.setObjectName("caption")
            row.addWidget(mark)
            row.addWidget(lbl, 1)
            row.addWidget(pct)
            lay.addLayout(row)
            self.steps.append((mark, lbl, pct))
        self.bar = QProgressBar()
        self.bar.setRange(0, 1000)
        self.bar.setTextVisible(False)
        self.bar.setFixedHeight(6)
        lay.addWidget(self.bar)
        foot = QHBoxLayout()
        self.status = QLabel()
        self.status.setObjectName("caption")
        self.cancel = QPushButton("取消")
        self.cancel.clicked.connect(state.cancel_analysis)
        foot.addWidget(self.status, 1)
        foot.addWidget(self.cancel)
        lay.addLayout(foot)
        state.changed.connect(lambda _t: self.refresh())
        self.refresh()

    WEIGHTS = [0.35, 0.30, 0.30, 0.05]

    def refresh(self):
        st = self.state
        show = st.phase in ("importing", "analyzing", "failed")
        self.setVisible(show)
        if not show:
            return
        importing, failed = st.phase == "importing", st.phase == "failed"
        stages = ["识别飞机","分析画面","定位/跟踪机头","评估画面清晰度","计算飞机轨迹"] if st.is_aircraft else STAGES
        weights = [.15,.05,.75,.04,.01] if st.is_aircraft else self.WEIGHTS
        for index,(mark, lbl, pct) in enumerate(self.steps):
            lbl.setText(stages[index] if index < len(stages) else "")
            for w in (mark, lbl, pct):
                w.setVisible(st.phase == "analyzing" and index < len(stages))
        self.bar.setVisible(st.phase == "analyzing")
        self.cancel.setVisible(st.phase == "analyzing")
        if importing:
            self.title.setText("正在读取照片…")
            self.sub.setText("")
            self.status.setText("")
        elif failed:
            self.title.setText("出错了")
            self.sub.setText(st.message)
            self.status.setText("请重新导入")
        else:
            fr = st.current_frames
            self.title.setText(f"正在分析 {len(fr)} 张照片")
            self.sub.setText(f"{fr[0].file_name} – {fr[-1].file_name}" if fr else "")
            k = stages.index(st.stage) if st.stage in stages else -1
            overall = 0.0
            if k >= 0:
                overall = min(1.0, sum(weights[:k]) + weights[k] * st.stage_progress)
            for j, (mark, lbl, pct) in enumerate(self.steps):
                if j < k:
                    mark.setText("✓")
                    mark.setStyleSheet(f"color: {theme.hexa(theme.OK)};")
                    lbl.setStyleSheet("")
                    pct.setText("")
                elif j == k:
                    mark.setText("●")
                    mark.setStyleSheet(f"color: {theme.hexa(theme.ACCENT)};")
                    lbl.setStyleSheet("")
                    pct.setText(f"{st.stage_progress * 100:.0f}%")
                else:
                    mark.setText("○")
                    mark.setStyleSheet(f"color: {theme.hexa(theme.TERTIARY)};")
                    lbl.setStyleSheet(f"color: {theme.hexa(theme.TERTIARY)};")
                    pct.setText("")
            self.bar.setValue(int(overall * 1000))
            el = time.time() - st.analysis_started
            if k < 0:
                txt = "等待上次分析结束…" if st.stage == "等待上次分析结束" else ("加载识别模型…" if st.stage == "加载识别模型" else "准备中…")
            elif overall > 0.04 and el > 2:
                remain = el * (1 - overall) / overall
                txt = f"{overall * 100:.0f}% · 约剩 {max(1, remain):.0f} 秒" if remain < 60 else f"{overall * 100:.0f}% · 约剩 {remain / 60:.0f} 分钟"
            else:
                txt = f"{overall * 100:.0f}%"
            if st.device_text:
                device = "机头定位：CPU" if st.is_aircraft and st.stage == "定位/跟踪机头" else st.device_text
                if not st.is_aircraft and st._models is not None and st.stage in STAGES:
                    device = st._models.device_for_stage(st.stage)
                txt += f" · {device}"
            self.status.setText(txt)
            self.status.setToolTip(st.device_text)
        self.adjustSize()


class DropZone(QFrame):
    def __init__(self, on_choose, parent=None):
        super().__init__(parent)
        self.targeted = False
        self.setObjectName("dropzone")
        lay = QVBoxLayout(self)
        lay.setContentsMargins(60, 50, 60, 50)
        lay.setSpacing(16)
        icon = QLabel("🐦")
        icon.setAlignment(Qt.AlignCenter)
        icon.setStyleSheet(f"font-size: 48px; background: {theme.hexa(theme.ACCENT, 0.12)}; border-radius: 55px;")
        icon.setFixedSize(110, 110)
        lay.addWidget(icon, 0, Qt.AlignCenter)
        t = QLabel("把连拍照片拖到这里")
        t.setStyleSheet("font-size: 22px; font-weight: 600;")
        t.setAlignment(Qt.AlignCenter)
        lay.addWidget(t)
        s = QLabel("支持 JPG / HEIF，整个文件夹或多选照片都可以。\n自动识别并锁定主体，一键生成连拍视频。")
        s.setObjectName("caption")
        s.setAlignment(Qt.AlignCenter)
        lay.addWidget(s)
        b = QPushButton("选择文件夹…")
        b.setObjectName("primary")
        b.clicked.connect(on_choose)
        lay.addWidget(b, 0, Qt.AlignCenter)
        self.set_targeted(False)

    def set_targeted(self, on: bool):
        c = theme.hexa(theme.ACCENT) if on else "rgba(255,255,255,0.18)"
        self.setStyleSheet(f"QFrame#dropzone {{ border: 2px dashed {c}; border-radius: 22px; }}")


class PreviewArea(QWidget):
    """Canvas + floating overlays."""

    def __init__(self, state, on_choose, parent=None):
        super().__init__(parent)
        self.state = state
        self.canvas = PreviewCanvas(state, self)
        self.tools = SourceToolBar(state, self)
        self.badges = FrameBadges(state, self)
        self.hint = HintLabel(state, self)
        self.card = StatusCard(state, self)
        self.drop = DropZone(on_choose, self)
        state.changed.connect(lambda t: self._layout() if t in ("phase", "view", "job", "analysis", "tool",
                                                                "watermark", "playing") else None)
        self._layout()

    def resizeEvent(self, _):
        self._layout()

    def showEvent(self, _):
        self._layout()          # the first layout runs before the window is shown: re-center now

    def _layout(self):
        st = self.state
        self.canvas.setGeometry(self.rect())
        empty = not st.frames and st.phase not in ("importing", "analyzing")
        self.drop.setVisible(empty and st.phase != "failed")
        self.drop.adjustSize()
        self.drop.move((self.width() - self.drop.width()) // 2, (self.height() - self.drop.height()) // 2)
        self.tools.move(12, 12)
        self.tools.raise_()
        self.badges.resize(self.badges.sizeHint())
        self.badges.move(self.width() - self.badges.width() - 12, 12)
        self.badges.raise_()
        self.hint.adjustSize()
        self.hint.move((self.width() - self.hint.width()) // 2, self.height() - self.hint.height() - 10)
        self.hint.raise_()
        if self.card.isVisible():
            self.card.adjustSize()
            self.card.move((self.width() - self.card.width()) // 2, (self.height() - self.card.height()) // 2)
            self.card.raise_()
