"""Transport bar and the timeline with picture + music lanes (port of Views/TimelineView.swift)."""
from __future__ import annotations

import math
import os

import numpy as np
from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QColor, QFont, QPainter, QPainterPath, QPen
from PySide6.QtWidgets import QFrame, QHBoxLayout, QLabel, QPushButton, QSizePolicy, QToolButton, QVBoxLayout, QWidget

from . import theme

PAD = 12.0


def fmt_time(t: float) -> str:
    t = max(0.0, t)
    return f"{int(t) // 60}:{t % 60:04.1f}"


class TransportBar(QFrame):
    def __init__(self, state, parent=None):
        super().__init__(parent)
        self.state = state
        self.setObjectName("panel")
        self.setFixedHeight(38)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(10, 4, 10, 4)
        lay.setSpacing(6)

        def tb(text, tip, fn, checkable=False):
            b = QToolButton()
            b.setText(text)
            b.setToolTip(tip)
            b.setCheckable(checkable)
            b.clicked.connect(fn)
            b.setFixedSize(30, 26)
            lay.addWidget(b)
            return b

        tb("⏮", "上一帧 ←", lambda: state.step(-1))
        self.play = tb("▶", "播放 / 暂停（空格）", state.toggle_play)
        tb("⏭", "下一帧 →", lambda: state.step(1))
        self.loop = tb("🔁", "循环播放", self._loop, checkable=True)
        self.loop.setChecked(True)
        self.sound = tb("🔊", "预览时播放 / 静音音乐", state.toggle_preview_audio)
        self.counter = QLabel()
        self.counter.setObjectName("value")
        self.fname = QLabel()
        self.fname.setObjectName("caption")
        self.fname.setMinimumWidth(40)
        self.fname.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Preferred)
        lay.addWidget(self.counter)
        lay.addWidget(self.fname, 1)
        self.summary = QLabel()
        self.summary.setObjectName("caption")
        lay.addWidget(self.summary)

        def btn(text, tip, fn):
            b = QPushButton(text)
            b.setToolTip(tip)
            b.clicked.connect(fn)
            lay.addWidget(b)
            return b

        btn("⇥ 起点", "从当前帧开始（之前的帧不导出）", self._trim_start)
        btn("⇤ 终点", "到当前帧结束", self._trim_end)
        self.clear = btn("✕", "清除起止点", self._trim_clear)
        self.exclude = btn("排除", "排除 / 恢复当前帧（X）", state.toggle_excluded)
        state.changed.connect(lambda _t: self.refresh())
        self.refresh()

    def _loop(self):
        self.state.loop_playback = self.loop.isChecked()

    def _trim_start(self):
        self.state.selection.trimStart = self.state.current_frame
        self.state.settings_changed("selection")

    def _trim_end(self):
        self.state.selection.trimEnd = self.state.current_frame
        self.state.settings_changed("selection")

    def _trim_clear(self):
        self.state.selection.trimStart, self.state.selection.trimEnd = 0, -1
        self.state.settings_changed("selection")

    def refresh(self):
        st = self.state
        self.play.setText("⏸" if st.playing else "▶")
        self.sound.setVisible(st.audio.active)
        self.sound.setText("🔊" if st.preview_audio else "🔇")
        a = st.analysis
        if a is not None and 0 <= st.current_frame < a.count:
            self.counter.setText(f"{st.current_frame + 1} / {a.count}")
            self.fname.setText(a.frames[st.current_frame].file_name)
            self.exclude.setText("恢复" if st.current_frame in a.excluded else "排除")
        if st.job is not None:
            j = st.job
            self.summary.setText(f"成片 {j.duration:.1f} 秒 · {len(j.output_frames)} 帧 · 用 {len(j.used)} 张")
        self.clear.setVisible(st.selection.trimStart > 0 or st.selection.trimEnd >= 0)


class FrameTimeline(QWidget):
    """Frame status strip + curves (bird motion, size, sharpness) with a draggable playhead."""

    def __init__(self, state, parent=None):
        super().__init__(parent)
        self.state = state
        self.setMinimumHeight(100)
        state.changed.connect(lambda t: self.update() if t in ("analysis", "job", "frame", "selection", "phase") else None)

    def _seek(self, x):
        a = self.state.analysis
        if a is None or a.count == 0:
            return
        f = min(1.0, max(0.0, (x - PAD) / max(1.0, self.width() - 2 * PAD)))
        self.state.stop()
        self.state.seek(int(round(f * (a.count - 1))))

    def mousePressEvent(self, ev):
        self._seek(ev.position().x())

    def mouseMoveEvent(self, ev):
        if ev.buttons() & Qt.LeftButton:
            self._seek(ev.position().x())

    def paintEvent(self, _):
        st = self.state
        a = st.analysis
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        if a is None or a.track is None or a.count == 0:
            return
        t = a.track
        n = a.count
        W, H = self.width(), self.height()
        w = W - 2 * PAD

        def x(i):
            return PAD + (0 if n == 1 else i / (n - 1)) * w

        cell = max(1.0, w / n)
        job = st.job
        for i in range(n):
            s = job.status[i] if job and i < len(job.status) else "ok"
            if s == "ok":
                c = theme.MANUAL if i in a.manualEye else theme.OK if t.eye_visible[i] else theme.WARN if t.has_data[i] else theme.BAD
            elif s == "blurry":
                c = QColor(235, 92, 84, 140)
            elif s == "untracked":
                c = theme.BAD
            else:
                c = QColor(255, 255, 255, 30)
            p.fillRect(QRectF(x(i) - cell / 2, 8, cell + 0.5, 12), c)
        top, bottom = 28.0, H - 18.0
        ch = bottom - top
        p.setFont(QFont(p.font().family(), 8))

        def curve(v, color, label, lx):
            v = np.asarray(v, dtype=np.float64)
            fin = v[np.isfinite(v)]
            if fin.size < 2 or fin.max() <= fin.min():
                return
            lo, hi = fin.min(), fin.max()
            path = QPainterPath()
            started = False
            for i in range(n):
                if not math.isfinite(v[i]):
                    continue
                pt = QPointF(x(i), bottom - (v[i] - lo) / (hi - lo) * ch)
                if not started:
                    path.moveTo(pt)
                    started = True
                else:
                    path.lineTo(pt)
            p.setPen(QPen(color, 1.2))
            p.drawPath(path)
            p.drawText(QPointF(lx, H - 5), label)

        curve(t.eye[:, 0], QColor(64, 217, 255, 215), "鸟眼 X", PAD)
        curve(t.eye[:, 1], QColor(64, 217, 255, 115), "鸟眼 Y", PAD + 52)
        curve(t.head_length, QColor(250, 184, 61, 205), "鸟头大小", PAD + 104)
        curve([pp.sharpness if pp.sharpness is not None else np.nan for pp in a.perFrame], QColor(255, 255, 255, 90), "清晰度", PAD + 168)
        if job:
            s0 = min(job.selection.trimStart, n - 1)
            e = n - 1 if job.selection.trimEnd < 0 else min(n - 1, job.selection.trimEnd)
            if s0 > 0:
                p.fillRect(QRectF(PAD, 0, x(s0) - PAD, H), QColor(0, 0, 0, 115))
            if e < n - 1:
                p.fillRect(QRectF(x(e), 0, W - PAD - x(e), H), QColor(0, 0, 0, 115))
        px = x(min(st.current_frame, n - 1))
        p.fillRect(QRectF(px - 0.75, 2, 1.5, H - 4), theme.ACCENT)
        p.setBrush(theme.ACCENT)
        p.setPen(Qt.NoPen)
        p.drawEllipse(QPointF(px, 6), 4, 4)
        legend = [(theme.OK, "鸟眼"), (theme.WARN, "鸟头推算"), (theme.MANUAL, "手动修正"), (theme.BAD, "未识别/模糊")]
        fm = p.fontMetrics()
        xx = W - PAD
        for color, label in reversed(legend):
            xx -= fm.horizontalAdvance(label) + 6
            p.setPen(theme.SECONDARY)
            p.drawText(QPointF(xx, H - 5), label)
            xx -= 10
            p.setPen(color)
            p.drawText(QPointF(xx, H - 5), "●")
            xx -= 8


class AudioLane(QWidget):
    """Whole song as a waveform; the highlighted window is the part that plays under the video."""

    def __init__(self, state, on_choose, parent=None):
        super().__init__(parent)
        self.state = state
        self.on_choose = on_choose
        self.setFixedHeight(48)
        self.setAcceptDrops(True)
        self._drag_off = None
        self._targeted = False
        self.remove = QToolButton(self)
        self.remove.setText("✕")
        self.remove.setToolTip("移除音乐")
        self.remove.clicked.connect(state.remove_audio)
        state.changed.connect(lambda t: self._changed(t))

    def _changed(self, t):
        if t in ("audio", "job", "frame", "playing"):
            self.update()

    def _geom(self):
        ov = self.state.audio_overview
        D = max(0.1, ov[0]) if ov else 1.0
        vd = self.state.job.duration if self.state.job else 0.0
        return D, vd, max(0.0, D - min(vd, D))

    def mousePressEvent(self, ev):
        st = self.state
        if not st.audio.path:
            self.on_choose()
            return
        if not st.audio_overview:
            return
        D, vd, mx = self._geom()
        w = self.width() - 2 * PAD
        t = (ev.position().x() - PAD) / w * D
        off = st.audio.startOffset
        self._drag_off = off if off <= t <= off + vd else min(max(0.0, t - vd / 2), mx)
        self._drag_x = ev.position().x()
        st.audio.startOffset = self._drag_off
        st.audio_settings_changed()

    def mouseMoveEvent(self, ev):
        if self._drag_off is None:
            return
        D, vd, mx = self._geom()
        w = self.width() - 2 * PAD
        self.state.audio.startOffset = min(max(0.0, self._drag_off + (ev.position().x() - self._drag_x) / w * D), mx)
        self.state.audio_settings_changed()

    def mouseReleaseEvent(self, _):
        self._drag_off = None

    def dragEnterEvent(self, ev):
        from .state import is_audio_file
        if ev.mimeData().hasUrls() and any(is_audio_file(u.toLocalFile()) for u in ev.mimeData().urls()):
            ev.acceptProposedAction()
            self._targeted = True
            self.update()

    def dragLeaveEvent(self, _):
        self._targeted = False
        self.update()

    def dropEvent(self, ev):
        from .state import is_audio_file
        self._targeted = False
        for u in ev.mimeData().urls():
            if is_audio_file(u.toLocalFile()):
                self.state.set_audio(u.toLocalFile())
                break

    def resizeEvent(self, _):
        self.remove.move(self.width() - 30, 4)

    def paintEvent(self, _):
        st = self.state
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        W, H = self.width(), self.height()
        self.remove.setVisible(bool(st.audio.path))
        if not st.audio.path:
            c = theme.MUSIC if self._targeted else QColor(255, 255, 255, 40)
            p.setPen(QPen(c, 1, Qt.DashLine))
            p.setBrush(Qt.NoBrush)
            p.drawRoundedRect(QRectF(PAD, 7, W - 2 * PAD, H - 14), 6, 6)
            p.setPen(theme.MUSIC if self._targeted else theme.SECONDARY)
            p.drawText(QRectF(0, 0, W, H), Qt.AlignCenter, "＋ 添加背景音乐 — 点击选择，或把音频文件拖到这里")
            return
        ov = st.audio_overview
        D, vd, _ = self._geom()
        w = W - 2 * PAD
        mid = H / 2
        if ov:
            off = st.audio.startOffset

            def x(t):
                return PAD + t / D * w

            win = QRectF(x(off), 4, max(2.0, x(min(D, off + vd)) - x(off)), H - 8)
            p.setPen(Qt.NoPen)
            p.setBrush(QColor(115, 158, 255, 40))
            p.drawRoundedRect(win, 4, 4)
            peaks = ov[1]
            bins_per_sec = len(peaks) / max(1e-6, ov[0])
            bars = max(1, int(w / 2))
            for b in range(bars):
                t0, t1 = b / bars * D, (b + 1) / bars * D
                i0 = int(t0 * bins_per_sec)
                i1 = max(i0 + 1, int(t1 * bins_per_sec))
                if i0 >= len(peaks):
                    break
                pk = float(peaks[i0:min(i1, len(peaks))].max())
                hh = max(1.0, pk ** 0.7 * (H / 2 - 7))
                inside = off - 1e-6 <= t0 and t1 <= off + vd + 1e-6
                p.fillRect(QRectF(PAD + b * 2, mid - hh, 1.2, 2 * hh), theme.MUSIC if inside else QColor(255, 255, 255, 56))
            p.setPen(QPen(theme.MUSIC, 1.2))
            p.setBrush(Qt.NoBrush)
            p.drawRoundedRect(win, 4, 4)
            job = st.job
            if job:
                k = st.playhead if st.playing else next((k for k, of in enumerate(job.output_frames) if of.a >= st.current_frame), 0)
                tm = off + k / job.export.outputFPS
                if st.audio.loop and tm >= D:
                    tm = (tm - D) % D
                if tm <= D:
                    p.fillRect(QRectF(x(tm) - 0.75, 2, 1.5, H - 4), theme.ACCENT)
            info = f"♪ {os.path.splitext(os.path.basename(st.audio.path))[0]}   从 {fmt_time(off)} 开始 · 全曲 {fmt_time(ov[0])}"
        else:
            info = f"♪ {os.path.basename(st.audio.path)}   " + (st.audio_message or "读取中…")
        p.setFont(QFont(p.font().family(), 8))
        fm = p.fontMetrics()
        tw = fm.horizontalAdvance(info) + 14
        p.setPen(Qt.NoPen)
        p.setBrush(QColor(28, 29, 32, 220))
        p.drawRoundedRect(QRectF(PAD + 4, 2, tw, 16), 8, 8)
        p.setPen(theme.WARN if st.audio_message else theme.TEXT)
        p.drawText(QPointF(PAD + 11, 14), info)


class TimelinePanel(QWidget):
    def __init__(self, state, on_choose_audio, parent=None):
        super().__init__(parent)
        self.setObjectName("panel")
        self.setFixedHeight(100 + 1 + 48)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)
        labels = QVBoxLayout()
        labels.setSpacing(0)
        for text, h in (("🎞\n画面", 100), ("♪\n音乐", 48)):
            l = QLabel(text)
            l.setAlignment(Qt.AlignCenter)
            l.setObjectName("caption")
            l.setFixedSize(52, h)
            labels.addWidget(l)
        lay.addLayout(labels)
        line = QFrame()
        line.setFrameShape(QFrame.VLine)
        line.setStyleSheet("color: rgba(255,255,255,0.08);")
        lay.addWidget(line)
        lanes = QVBoxLayout()
        lanes.setSpacing(0)
        self.frames = FrameTimeline(state)
        self.frames.setFixedHeight(100)
        self.audio = AudioLane(state, on_choose_audio)
        lanes.addWidget(self.frames)
        sep = QFrame()
        sep.setFrameShape(QFrame.HLine)
        sep.setStyleSheet("color: rgba(255,255,255,0.08);")
        lanes.addWidget(sep)
        lanes.addWidget(self.audio)
        lay.addLayout(lanes, 1)
