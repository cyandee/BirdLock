"""Settings panel with 构图 / 画面 / 输出 tabs (port of Views/InspectorView.swift) plus a hardware card."""
from __future__ import annotations

import math
import os
import threading

from PySide6.QtCore import QRectF, QSize, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QDoubleValidator, QPainter, QPen, QPixmap
from PySide6.QtWidgets import (QButtonGroup, QCheckBox, QComboBox, QDoubleSpinBox, QFrame, QGridLayout,
                               QHBoxLayout, QLabel, QLayout, QLineEdit, QPushButton, QScrollArea, QSizePolicy, QSlider,
                               QSpinBox, QStackedWidget, QTabBar, QVBoxLayout, QWidget)

from . import theme
from .timeline import fmt_time
from ..core import gpu
from ..core.settings import (ASPECT_PRESETS, FPS_PRESETS, FRAMING_RANGE, PRESETS, SHORT_SIDE_PRESETS, SPEED_PRESETS,
                             AspectRatio, EdgeFill, FocusMarkColor, FocusMarkStyle, FrameInterpolation, LockPoint, LoopMode,
                             OverlayCorner, RotationMode, SizeMode, VideoCodec, VideoQuality)


class Card(QFrame):
    def __init__(self, title: str, icon: str = ""):
        super().__init__()
        self.setObjectName("card")
        self.lay = QVBoxLayout(self)
        self.lay.setContentsMargins(12, 10, 12, 12)
        self.lay.setSpacing(8)
        t = QLabel(f"{icon}  {title}" if icon else title)
        t.setObjectName("cardTitle")
        self.lay.addWidget(t)

    def add(self, w):
        if isinstance(w, QWidget):
            self.lay.addWidget(w)
        else:
            self.lay.addLayout(w)
        return w


def caption(text: str, name: str = "caption") -> QLabel:
    l = QLabel(text)
    l.setObjectName(name)
    l.setWordWrap(True)
    return l


class Bindings:
    """Keeps controls in sync with the state without feedback loops."""

    def __init__(self):
        self.refreshers = []

    def add(self, fn):
        self.refreshers.append(fn)

    def refresh(self):
        for fn in self.refreshers:
            fn()


class Tab(QScrollArea):
    def __init__(self, state):
        super().__init__()
        self.state = state
        self.setObjectName("inspector")
        self.setWidgetResizable(True)
        self.setFrameShape(QFrame.NoFrame)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        body = QWidget()
        self.v = QVBoxLayout(body)
        self.v.setContentsMargins(10, 10, 10, 10)
        self.v.setSpacing(10)
        # Never let the content's minimum width grow the body beyond the viewport: by default the
        # body reports the layout's minimum-size-hint (~360 px > the 330 px panel), so it overflows
        # and every row gets clipped on the right. A tiny explicit minimum (>0, so it overrides the
        # hint) plus an Ignored horizontal policy lets the scroll area shrink the body to the panel.
        self.v.setSizeConstraint(QLayout.SetNoConstraint)
        body.setMinimumWidth(1)
        body.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Preferred)
        self.setWidget(body)
        self.b = Bindings()

    # ---- control factories (all bound to the state)

    def bound_text(self, widget, text):
        if callable(text):
            widget.setText(text())
            self.b.add(lambda: widget.setText(text()))
        return widget

    def slider(self, card: Card, title, get, set_, lo, hi, fmt, log=False, step=None, tip=None, topic="settings"):
        box = QWidget()
        v = QVBoxLayout(box)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(2)
        h = QHBoxLayout()
        t = self.bound_text(QLabel(title if isinstance(title,str) else title()),title)
        val = QLabel()
        val.setObjectName("value")
        h.addWidget(t)
        h.addStretch(1)
        h.addWidget(val)
        v.addLayout(h)
        s = QSlider(Qt.Horizontal)
        s.setRange(0, 1000)
        v.addWidget(s)
        if tip:
            box.setToolTip(tip)
        f = (lambda x: math.log(x)) if log else (lambda x: x)
        fi = (lambda y: math.exp(y)) if log else (lambda y: y)
        a, b = f(lo), f(hi)

        def to_slider(x):
            return int(round((f(min(max(x, lo), hi)) - a) / (b - a) * 1000))

        def from_slider(k):
            x = fi(a + (b - a) * k / 1000)
            if step:
                x = round(x / step) * step
            return x

        def changed(k):
            x = from_slider(k)
            set_(x)
            val.setText(fmt(x))
            if topic == "audio":
                self.state.audio_settings_changed()
            elif topic == "watermark":
                self.state.watermark_changed()
            else:
                self.state.settings_changed(topic)

        s.valueChanged.connect(changed)

        def refresh():
            x = get()
            s.blockSignals(True)
            s.setValue(to_slider(x))
            s.blockSignals(False)
            val.setText(fmt(x))

        self.b.add(refresh)
        card.add(box)
        return box

    def combo(self, card: Card | None, label, items, get, set_, topic="settings", tip=None):
        """items: [(title, value)]"""
        c = QComboBox()
        c.setMinimumWidth(0)               # long entries must not force the panel wider
        c.setSizeAdjustPolicy(QComboBox.AdjustToMinimumContentsLengthWithIcon)
        c.setMinimumContentsLength(4)
        dynamic_items = items if callable(items) else None
        bound_items = list(items() if dynamic_items else items)
        for title, value in bound_items:
            c.addItem(title, value)
        if tip:
            c.setToolTip(tip)

        def changed(k):
            if not 0 <= k < len(bound_items):
                return
            # QVariant converts str-derived Enum values to plain str. Keep the
            # Python value so codec.ext / quality.bpp remain available until restart.
            set_(bound_items[k][1])
            if topic == "audio":
                self.state.audio_settings_changed()
            elif topic == "watermark":
                self.state.watermark_changed()
            else:
                self.state.settings_changed(topic)

        c.currentIndexChanged.connect(changed)

        def refresh():
            nonlocal bound_items
            if dynamic_items:
                values = list(dynamic_items())
                if [(c.itemText(k),c.itemData(k)) for k in range(c.count())] != values:
                    c.blockSignals(True);c.clear()
                    for title,value in values:c.addItem(title,value)
                    c.blockSignals(False)
                bound_items = values
            v = get()
            for k in range(c.count()):
                if c.itemData(k) == v:
                    c.blockSignals(True)
                    c.setCurrentIndex(k)
                    c.blockSignals(False)
                    return

        self.b.add(refresh)
        if card is not None:
            roww = QWidget()
            row = QHBoxLayout(roww)
            row.setContentsMargins(0, 0, 0, 0)
            l = self.bound_text(QLabel(label if isinstance(label,str) else label()),label)
            l.setObjectName("caption")
            l.setFixedWidth(52)
            row.addWidget(l)
            row.addWidget(c, 1)
            card.add(roww)
            c.row = roww
        return c

    def check(self, card: Card, text, get, set_, topic="settings", tip=None):
        cb = self.bound_text(QCheckBox(text if isinstance(text,str) else text()),text)
        cb.setMinimumWidth(0)              # long labels must not force the panel wider
        if tip:
            cb.setToolTip(tip)

        def changed(on):
            set_(bool(on))
            if topic == "audio":
                self.state.audio_settings_changed()
            elif topic == "watermark":
                self.state.watermark_changed()
            else:
                self.state.settings_changed(topic)

        cb.toggled.connect(changed)

        def refresh():
            cb.blockSignals(True)
            cb.setChecked(bool(get()))
            cb.blockSignals(False)

        self.b.add(refresh)
        card.add(cb)
        return cb

    def visible_when(self, w: QWidget, cond):
        self.b.add(lambda: w.setVisible(bool(cond())))

    def status(self, card: Card, fn):
        """Label whose (text, style) comes from fn() → (text, objectName) or None."""
        l = QLabel()
        l.setWordWrap(True)

        def refresh():
            r = fn()
            l.setVisible(r is not None)
            if r:
                l.setText(r[0])
                if l.objectName() != r[1]:
                    l.setObjectName(r[1])
                    l.style().unpolish(l)
                    l.style().polish(l)
        self.b.add(refresh)
        card.add(l)
        return l


# ---------------------------------------------------------------------------------------------- 构图


class AnchorPad(QWidget):
    changed = Signal()

    def __init__(self, state):
        super().__init__()
        self.state = state
        self.setFixedSize(104, 104)

    def _rect(self):
        a = self.state.export.aspect.value
        s = min(self.width() / a, self.height())
        w, h = a * s, s
        return QRectF((self.width() - w) / 2, (self.height() - h) / 2, w, h)

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = self._rect()
        p.setBrush(QColor(0, 0, 0, 128))
        p.setPen(QPen(QColor(255, 255, 255, 76)))
        p.drawRoundedRect(r, 4, 4)
        p.setPen(QPen(QColor(255, 255, 255, 38), 0.5))
        for f in (1 / 3, 2 / 3):
            p.drawLine(r.x() + r.width() * f, r.y(), r.x() + r.width() * f, r.bottom())
            p.drawLine(r.x(), r.y() + r.height() * f, r.right(), r.y() + r.height() * f)
        c = self.state.composition
        p.setBrush(theme.EYE)
        p.setPen(QPen(QColor(255, 255, 255), 1.5))
        p.drawEllipse(r.x() + c.anchorX * r.width() - 6, r.y() + c.anchorY * r.height() - 6, 12, 12)

    def _set(self, pos):
        r = self._rect()
        self.state.composition.anchorX = min(0.95, max(0.05, (pos.x() - r.x()) / r.width()))
        self.state.composition.anchorY = min(0.95, max(0.05, (pos.y() - r.y()) / r.height()))
        self.state.settings_changed()
        self.update()

    def mousePressEvent(self, ev):
        self._set(ev.position())

    def mouseMoveEvent(self, ev):
        if ev.buttons() & Qt.LeftButton:
            self._set(ev.position())


class ComposeTab(Tab):
    def __init__(self, state):
        super().__init__(state)
        st = state
        c = lambda: st.composition   # noqa: E731

        card = Card("构图风格", "✨")
        grid = QGridLayout()
        grid.setSpacing(6)
        self.preset_btns = []
        for k, pr in enumerate(st.presets):
            b = QPushButton(pr.name)
            b.setObjectName("chip")
            b.setCheckable(True)
            b.setToolTip(pr.detail)
            b.clicked.connect(lambda _=False, k=k: st.apply_preset(st.presets[k]))
            grid.addWidget(b, k // 3, k % 3)
            self.preset_btns.append((b, pr))
        card.add(grid)
        def refresh_presets():
            for k,(button,_) in enumerate(self.preset_btns):
                preset = st.presets[k]
                button.setText(preset.name);button.setToolTip(preset.detail);button.setChecked(st.is_preset_active(preset))
        self.b.add(refresh_presets)
        self.v.addWidget(card)

        card = Card("锁定", "◎")
        self.combo(card, "锁定点", lambda: [("机头",LockPoint.HEAD_CENTER)] if st.is_aircraft else [(x.title,x) for x in LockPoint], lambda: c().lockPoint, lambda v: setattr(c(), "lockPoint", v))
        self.slider(card, "跟随方式", lambda: c().followSoftness, lambda v: setattr(c(), "followSoftness", v), 0, 1,
                    lambda v: "硬锁定" if v < 0.02 else f"柔和 {v * 100:.0f}%",
                    tip="0 = 锁定点固定在画面一点；往右拉，镜头像摄像机一样柔和跟随，主体在画面中轻微浮动")
        self.v.addWidget(card)

        card = Card("画面位置", "⌖")
        row = QHBoxLayout()
        self.pad = AnchorPad(st)
        row.addWidget(self.pad)
        col = QVBoxLayout()
        col.addWidget(caption("拖动小圆点，设置锁定点在成片中的位置。也可以在「原图+识别」里直接拖动取景框。"))
        lead = QCheckBox("飞行方向自动留白")
        lead.setToolTip("主体朝左飞时自动镜像水平位置，让主体的前方留出空间")
        lead.toggled.connect(lambda on: (setattr(c(), "autoLeadRoom", on), st.settings_changed()))
        self.b.add(lambda: (lead.blockSignals(True), lead.setChecked(c().autoLeadRoom), lead.blockSignals(False)))
        col.addWidget(lead)
        hb = QHBoxLayout()
        for label, x, y in (("居中", 0.5, 0.5), ("三分", 1 / 3, 1 / 3)):
            b = QPushButton(label)
            b.clicked.connect(lambda _=False, x=x, y=y: (setattr(c(), "anchorX", x), setattr(c(), "anchorY", y), st.settings_changed()))
            hb.addWidget(b)
        hb.addStretch(1)
        col.addLayout(hb)
        row.addLayout(col, 1)
        card.add(row)
        self.b.add(self.pad.update)
        self.v.addWidget(card)

        card = Card("取景", "⛶")
        # framing: typed value + log slider + ± + use whole photo
        top = QHBoxLayout()
        top.addWidget(QLabel("取景范围"))
        top.addStretch(1)
        top.addWidget(caption("短边 = 头长 ×"))
        spin = QLineEdit()
        spin.setFixedWidth(64)
        spin.setAlignment(Qt.AlignRight)
        spin.setValidator(QDoubleValidator(FRAMING_RANGE[0], FRAMING_RANGE[1], 1))
        spin.setToolTip(f"直接输入数值（{FRAMING_RANGE[0]:g}–{FRAMING_RANGE[1]:g}），回车确认")

        def framing_typed():
            try:
                c().framing = min(FRAMING_RANGE[1], max(FRAMING_RANGE[0], float(spin.text())))
            except ValueError:
                return
            st.settings_changed()
        spin.editingFinished.connect(framing_typed)
        top.addWidget(spin)
        card.add(top)
        srow = QHBoxLayout()
        minus, plus = QPushButton("−"), QPushButton("+")
        for bt in (minus, plus):
            bt.setFixedWidth(28)
        minus.setToolTip("收紧取景（主体更大）")
        plus.setToolTip("放宽取景（主体更小）")
        sl = QSlider(Qt.Horizontal)
        sl.setRange(0, 1000)
        lo, hi = math.log(FRAMING_RANGE[0]), math.log(FRAMING_RANGE[1])
        sl.valueChanged.connect(lambda k: (setattr(c(), "framing", math.exp(lo + (hi - lo) * k / 1000)), st.settings_changed()))

        def nudge(f):
            c().framing = min(FRAMING_RANGE[1], max(FRAMING_RANGE[0], c().framing * f))
            st.settings_changed()
        minus.clicked.connect(lambda: nudge(1 / 1.15))
        plus.clicked.connect(lambda: nudge(1.15))
        srow.addWidget(minus)
        srow.addWidget(sl, 1)
        srow.addWidget(plus)
        card.add(srow)

        def ref_framing():
            for w in (spin, sl):
                w.blockSignals(True)
            if not spin.hasFocus():
                spin.setText(f"{c().framing:.1f}")
            sl.setValue(int(round((math.log(c().framing) - lo) / (hi - lo) * 1000)))
            for w in (spin, sl):
                w.blockSignals(False)
        self.b.add(ref_framing)
        brow = QHBoxLayout()
        brow.addWidget(caption("主体更大"))
        brow.addStretch(1)
        full = QPushButton("用满原图")
        full.setObjectName("link")
        full.setToolTip("取景框尽量大，直到原图边缘")
        full.clicked.connect(lambda: (setattr(c(), "framing", FRAMING_RANGE[1]), st.settings_changed()))
        brow.addWidget(full)
        brow.addStretch(1)
        brow.addWidget(caption("主体更小"))
        card.add(brow)
        self.status(card, lambda: (f"已到原图大小上限（{st.job.plan.image_limited_frames} 帧），再放宽不会更广", "caption")
                    if st.job and st.job.plan.image_limited_frames > 0 and c().edgeFill == EdgeFill.SHIFT else None)
        self.combo(card, "大小", [(x.title, x) for x in SizeMode], lambda: c().sizeMode, lambda v: setattr(c(), "sizeMode", v))
        sm = self.slider(card, "大小平滑", lambda: c().sizeSmoothing, lambda v: setattr(c(), "sizeSmoothing", v), 2, 60,
                         lambda v: f"{v:.0f} 帧", tip="越大，主体大小变化越平缓")
        self.visible_when(sm, lambda: c().sizeMode == SizeMode.LOCK_SIZE)
        self.v.addWidget(card)

        card = Card("画面边缘", "▭")
        self.combo(card, "越界时", [(x.title, x) for x in EdgeFill], lambda: c().edgeFill, lambda v: setattr(c(), "edgeFill", v))
        expl = caption("主体到原图边缘时，取景框在原图内平移，尽量用满原图像素；主体会暂时离开锁定点，但不会贴边。")
        card.add(expl)
        m1 = self.slider(card, "锁定点离画面边缘至少", lambda: c().edgeMargin, lambda v: setattr(c(), "edgeMargin", v), 0, 0.3,
                         lambda v: f"{v * 100:.0f}%", tip="取景框平移后，锁定点与成片边缘保持的最小距离")
        m2 = self.slider(card, "为此最多放大", lambda: c().maxEdgeZoom, lambda v: setattr(c(), "maxEdgeZoom", v), 1, 3,
                         lambda v: "不放大" if v < 1.01 else f"{v:.1f}×",
                         tip="主体太靠近原图边缘时，允许稍微放大来保持上面的距离。设为「不放大」则只平移")
        for w in (expl, m1, m2):
            self.visible_when(w, lambda: c().edgeFill == EdgeFill.SHIFT)

        def edge_status():
            if not st.job:
                return None
            pl = st.job.plan
            if c().edgeFill == EdgeFill.SHIFT and pl.shifted_frames:
                return (f"✓ {pl.shifted_frames} 帧主体靠近原图边缘，已平移取景" + (f"（{pl.zoomed_frames} 帧略微放大）" if pl.zoomed_frames else ""), "ok")
            if c().edgeFill == EdgeFill.AUTO_ZOOM and pl.zoomed_frames:
                return (f"{pl.zoomed_frames} 帧放大以避免越界", "warn")
            if c().edgeFill in (EdgeFill.BLUR_EXTEND, EdgeFill.BLACK) and pl.out_of_bounds_frames:
                return (f"⚠ {pl.out_of_bounds_frames} 帧的取景超出原图边缘", "warn")
            return None
        self.status(card, edge_status)
        self.v.addWidget(card)

        card = Card("旋转", "↻")
        self.combo(card, "旋转", [(x.title, x) for x in RotationMode], lambda: c().rotationMode, lambda v: setattr(c(), "rotationMode", v))
        self.slider(card, "角度微调", lambda: c().rotationOffsetDeg, lambda v: setattr(c(), "rotationOffsetDeg", v), -30, 30,
                    lambda v: f"{v:+.1f}°", step=0.5)
        self.v.addWidget(card)
        self.v.addStretch(1)


# ---------------------------------------------------------------------------------------------- 画面


class LookTab(Tab):
    def __init__(self, state):
        super().__init__(state)
        st = state
        L = lambda: st.look          # noqa: E731
        S = lambda: st.selection     # noqa: E731

        card = Card("亮度一致性", "☀")
        self.check(card, "去闪烁（统一相邻帧的曝光和白平衡）", lambda: L().deflicker, lambda v: setattr(L(), "deflicker", v))
        a = self.slider(card, "强度", lambda: L().deflickerStrength, lambda v: setattr(L(), "deflickerStrength", v), 0, 1, lambda v: f"{v * 100:.0f}%")
        b = self.slider(card, "平滑窗口", lambda: L().deflickerWindow, lambda v: setattr(L(), "deflickerWindow", v), 2, 30, lambda v: f"{v:.0f} 帧")
        for w in (a, b):
            self.visible_when(w, lambda: L().deflicker)
        self.slider(card, "曝光", lambda: L().exposureEV, lambda v: setattr(L(), "exposureEV", v), -1.5, 1.5, lambda v: f"{v:+.2f} EV", step=0.05)
        self.v.addWidget(card)

        card = Card("选帧", "🎞")
        self.check(card, "跳过模糊帧", lambda: S().dropBlurry, lambda v: setattr(S(), "dropBlurry", v),
                   tip="按锁定区域的清晰度自动跳过失焦、拖影的帧")
        th = self.slider(card, "模糊判定", lambda: S().blurThreshold, lambda v: setattr(S(), "blurThreshold", v), 0.2, 0.95,
                         lambda v: f"低于中位数 {v * 100:.0f}%")
        self.visible_when(th, lambda: S().dropBlurry)
        self.status(card, lambda: (f"将跳过 {st.job.status.count('blurry')} 帧", "caption") if S().dropBlurry and st.job else None)
        self.check(card, lambda: "跳过未定位机头的帧" if st.is_aircraft else "跳过未识别到鸟的帧", lambda: S().dropUntracked, lambda v: setattr(S(), "dropUntracked", v))
        ex_row = QHBoxLayout()
        ex_lbl = caption("")
        ex_btn = QPushButton("全部恢复")
        ex_btn.clicked.connect(st.restore_all_excluded)
        ex_row.addWidget(ex_lbl, 1)
        ex_row.addWidget(ex_btn)
        ex_w = QWidget()
        ex_w.setLayout(ex_row)
        card.add(ex_w)

        def ref_ex():
            n = len(st.analysis.excluded) if st.analysis else 0
            ex_w.setVisible(n > 0)
            ex_lbl.setText(f"手动排除了 {n} 帧")
        self.b.add(ref_ex)
        self.v.addWidget(card)

        card = Card("识别与修正", "🐦")
        self.status(card, lambda: ((f"机头已定位：{int(st.analysis.track.has_data.sum())}/{st.analysis.count} 帧" if st.is_aircraft else f"识别到鸟：{int(st.analysis.track.has_data.sum())}/{st.analysis.count} 帧，其中鸟眼可见 "
                                   f"{int(st.analysis.track.eye_visible.sum())} 帧"), "caption")
                    if st.analysis and st.analysis.track is not None else None)
        pr_row = QHBoxLayout()
        pr_lbl = caption("", "warn")
        pr_btn = QPushButton("逐帧检查")
        pr_btn.clicked.connect(lambda: (st.start_fixing_eye(), st.jump_to_predicted(1)))
        pr_row.addWidget(pr_lbl, 1)
        pr_row.addWidget(pr_btn)
        pr_w = QWidget()
        pr_w.setLayout(pr_row)
        card.add(pr_w)
        man_row = QHBoxLayout()
        man_lbl = caption("", "manual")
        man_btn = QPushButton("清除全部修正")
        man_btn.clicked.connect(lambda: st.clear_manual_eye(True))
        man_row.addWidget(man_lbl, 1)
        man_row.addWidget(man_btn)
        man_w = QWidget()
        man_w.setLayout(man_row)
        card.add(man_w)

        def ref_fix():
            n = len(st.predicted_frames)
            pr_w.setVisible(n > 0 and not st.is_aircraft)
            pr_lbl.setText(f"{n} 帧鸟眼被遮挡，位置为推算")
            m = len(st.analysis.manualEye) if st.analysis else 0
            man_w.setVisible(m > 0)
            man_lbl.setText(f"手动修正 {m} 帧")
        self.b.add(ref_fix)
        note = caption("")
        self.b.add(lambda: note.setText("飞机识别为试验功能，复杂视角可能误定位。请逐帧检查；切到「原图+识别」，点「修正机头」后标记当前帧机头。" if st.is_aircraft else "修正方法：切换到「原图+识别」，点「修正鸟眼」，在鸟眼的准确位置点击（或拖动圆圈）。前后帧会自动重新计算。"))
        card.add(note)
        row = QHBoxLayout()
        b1, b2 = QPushButton("修正鸟眼"), QPushButton("重新识别")
        self.b.add(lambda: b1.setText("修正机头" if st.is_aircraft else "修正鸟眼"))
        b1.clicked.connect(st.start_fixing_eye)
        b2.clicked.connect(lambda: st.start_analysis(fresh=True))
        row.addWidget(b1)
        row.addWidget(b2)
        row.addStretch(1)
        card.add(row)
        self.v.addWidget(card)
        self.v.addStretch(1)


# ---------------------------------------------------------------------------------------------- 输出


class OutputTab(Tab):
    def __init__(self, state, choose_audio, choose_watermark):
        super().__init__(state)
        st = state
        E = lambda: st.export        # noqa: E731

        card = Card("画面比例", "▢")
        grid = QGridLayout()
        grid.setSpacing(6)
        self.aspect_btns = []
        for k, ar in enumerate(ASPECT_PRESETS):
            b = QPushButton(ar.label.split(" ")[0])
            b.setObjectName("chip")
            b.setCheckable(True)
            b.setToolTip(ar.label)
            b.clicked.connect(lambda _=False, ar=ar: (setattr(E(), "aspect", ar.copy()), st.settings_changed()))
            grid.addWidget(b, k // 4, k % 4)
            self.aspect_btns.append((b, ar))
        card.add(grid)
        self.b.add(lambda: [b.setChecked(E().aspect.label == ar.label) for b, ar in self.aspect_btns])
        cr = QHBoxLayout()
        cr.addWidget(caption("自定义"))
        cw, ch = QDoubleSpinBox(), QDoubleSpinBox()
        for s, v in ((cw, 4), (ch, 5)):
            s.setRange(0.1, 100)
            s.setDecimals(2)
            s.setValue(v)
            s.setFixedWidth(64)
        apply_b = QPushButton("应用")

        def apply_custom():
            w, h = cw.value(), ch.value()
            fm = lambda x: str(int(x)) if float(x).is_integer() else f"{x:g}"   # noqa: E731
            E().aspect = AspectRatio(w, h, f"{fm(w)}:{fm(h)}")
            st.settings_changed()
        apply_b.clicked.connect(apply_custom)
        cr.addWidget(cw)
        cr.addWidget(QLabel(":"))
        cr.addWidget(ch)
        cr.addWidget(apply_b)
        cr.addStretch(1)
        card.add(cr)
        self.v.addWidget(card)

        card = Card("分辨率与帧率", "🖥")
        self.combo(card, "短边", [(f"{x} px", x) for x in SHORT_SIDE_PRESETS], lambda: E().shortSide, lambda v: setattr(E(), "shortSide", v))
        self.status(card, lambda: (f"输出 {E().output_size[0]} × {E().output_size[1]}", "caption"))

        def up_status():
            if not st.job:
                return None
            up = st.job.plan.max_upscale
            if up > 1.05:
                return (f"⚠ 最大放大 {up:.1f}×：原图像素不足，画面会略软。可减小分辨率或放宽取景。", "warn")
            return (f"✓ 原图像素充足（最大使用 {up * 100:.0f}%）", "ok")
        self.status(card, up_status)
        self.combo(card, "帧率", [(f"{x:g} fps", x) for x in FPS_PRESETS], lambda: E().outputFPS, lambda v: setattr(E(), "outputFPS", v))
        self.v.addWidget(card)

        card = Card("速度与循环", "⏱")

        def speed_label(s):
            if abs(s - 1) < 1e-6:
                return "原速 1×"
            return f"慢放 {s:.2g}×" if s < 1 else f"快放 {s:.2g}×"
        self.combo(card, "速度", [(speed_label(x), x) for x in SPEED_PRESETS], lambda: E().speed, lambda v: setattr(E(), "speed", v))
        self.status(card, lambda: (f"连拍 {st.analysis.fps:.0f} 张/秒，成片每秒展示 {st.analysis.fps * E().speed:.1f} 张连拍", "caption")
                    if st.analysis else None)
        self.combo(card, "补帧", [(x.title, x) for x in FrameInterpolation], lambda: E().interpolation, lambda v: setattr(E(), "interpolation", v))
        self.combo(card, "顺序", [(x.title, x) for x in LoopMode], lambda: E().loop, lambda v: setattr(E(), "loop", v))
        self.combo(card, "重复", [(f"{k} 次", k) for k in range(1, 11)], lambda: E().repeatCount, lambda v: setattr(E(), "repeatCount", v))
        self.slider(card, "淡入", lambda: E().fadeInSeconds, lambda v: setattr(E(), "fadeInSeconds", v), 0, 2, lambda v: f"{v:.1f} 秒", step=0.1)
        self.slider(card, "淡出", lambda: E().fadeOutSeconds, lambda v: setattr(E(), "fadeOutSeconds", v), 0, 2, lambda v: f"{v:.1f} 秒", step=0.1)
        self.v.addWidget(card)

        card = Card("编码", "🎬")
        self.combo(card, "格式", [(x.title, x) for x in VideoCodec], lambda: E().codec, lambda v: setattr(E(), "codec", v))
        q = self.combo(card, "质量", [(x.title, x) for x in VideoQuality], lambda: E().quality, lambda v: setattr(E(), "quality", v))
        self.visible_when(q.row, lambda: E().codec in (VideoCodec.H264, VideoCodec.HEVC))
        self.v.addWidget(card)

        self.v.addWidget(self._hardware_card())
        self.v.addWidget(self._focus_card())
        from .project_editor import ProjectEditor, MusicCueCard
        self.v.addWidget(ProjectEditor(self.state))
        self.v.addWidget(self._music_card(choose_audio))
        self.v.addWidget(MusicCueCard(self.state))
        from .audio_tracks import AudioTracksCard
        self.v.addWidget(AudioTracksCard(self.state))
        self.v.addWidget(self._watermark_card(choose_watermark))

        card = Card("文字水印", "T")
        self.check(card, "显示拍摄参数（快门/光圈/ISO 等）", lambda: E().overlay.showExif, lambda v: setattr(E().overlay, "showExif", v))
        pf = self.check(card, "逐帧显示参数", lambda: E().overlay.exifPerFrame, lambda v: setattr(E().overlay, "exifPerFrame", v))
        self.visible_when(pf, lambda: E().overlay.showExif)
        txt = QLineEdit()
        txt.setPlaceholderText("自定义文字（如署名、鸟种）")
        txt.textChanged.connect(lambda t: (setattr(E().overlay, "customText", t), st.settings_changed()))
        self.b.add(lambda: None if txt.hasFocus() else (txt.blockSignals(True), txt.setText(E().overlay.customText), txt.blockSignals(False)))
        card.add(txt)
        self.combo(card, "位置", [(x.title, x) for x in OverlayCorner], lambda: E().overlay.corner, lambda v: setattr(E().overlay, "corner", v))
        self.slider(card, "字号", lambda: E().overlay.textScale, lambda v: setattr(E().overlay, "textScale", v), 0.5, 2.5, lambda v: f"{v:.1f}×")
        self.v.addWidget(card)
        self.v.addStretch(1)

    def _hardware_card(self) -> Card:
        st = self.state
        card = Card("硬件加速", "⚡")
        items = [("自动（优先独立显卡）", "auto")]
        for ad in gpu.list_adapters():
            if not ad.software:
                items.append((f"{ad.name}（{ad.dedicated_mb // 1024} GB）" if ad.dedicated_mb >= 1024 else ad.name, f"gpu:{ad.index}"))
        items.append(("仅用 CPU", "cpu"))
        dev = QComboBox()
        for t, v in items:
            dev.addItem(t, v)
        dev.currentIndexChanged.connect(lambda k: st.set_device(dev.itemData(k)))

        def ref_dev():
            for k in range(dev.count()):
                if dev.itemData(k) == st.device:
                    dev.blockSignals(True)
                    dev.setCurrentIndex(k)
                    dev.blockSignals(False)
        self.b.add(ref_dev)
        row = QHBoxLayout()
        l = caption("AI 识别")
        l.setFixedWidth(52)
        row.addWidget(l)
        row.addWidget(dev, 1)
        card.add(row)
        self.status(card, lambda: (f"当前：{st.device_text}", "caption") if st.device_text else ("下次识别时加载到所选设备", "caption"))
        cl = QCheckBox("图像缩放用显卡（OpenCL）")
        cl.setToolTip("渲染和导出时用显卡做重采样。个别显卡驱动有问题时可以关掉")
        cl.toggled.connect(st.set_gpu_image)
        self.b.add(lambda: (cl.blockSignals(True), cl.setChecked(st.gpu_image), cl.blockSignals(False)))
        card.add(cl)
        self.status(card, lambda: (f"OpenCL 设备：{gpu.opencl_device_name()}", "caption") if st.gpu_image and gpu.opencl_device_name() else None)
        enc = QComboBox()
        enc.addItem(gpu.ENCODER_TITLES["auto"], "auto")
        enc.currentIndexChanged.connect(lambda k: (setattr(st.export, "encoder", enc.itemData(k)), st.save_settings()))
        row = QHBoxLayout()
        l = caption("视频编码")
        l.setFixedWidth(52)
        row.addWidget(l)
        row.addWidget(enc, 1)
        card.add(row)
        enc_status = caption("正在检测显卡编码器…")
        card.add(enc_status)

        def ref_enc():
            for k in range(enc.count()):
                if enc.itemData(k) == st.export.encoder:
                    enc.blockSignals(True)
                    enc.setCurrentIndex(k)
                    enc.blockSignals(False)
        self.b.add(ref_enc)

        def detect():
            W, H = st.export.output_size
            fams = gpu.available_encoder_families(W, H, cancelled=lambda: st._closing)

            def done():
                for f in fams:
                    enc.addItem(gpu.ENCODER_TITLES.get(f, f), f)
                hw = [gpu.ENCODER_TITLES[f] for f in fams if f != "software"]
                enc_status.setText("可用的显卡编码：" + "、".join(hw) if hw else "没有检测到显卡编码器，将使用 CPU 编码")
                ref_enc()
            st.on_main(done)
        threading.Thread(target=detect, daemon=True).start()
        return card

    def _focus_card(self) -> Card:
        st = self.state
        Fm = lambda: st.export.focusMark   # noqa: E731
        card = Card("对焦框", "⌗")
        self.check(card, "在成片里显示对焦点", lambda: Fm().enabled, lambda v: setattr(Fm(), "enabled", v),
                   tip="模拟相机对焦，在锁定位置绘制对焦框，让观众看到焦点")
        box = QWidget()
        v = QVBoxLayout(box)
        v.setContentsMargins(0, 0, 0, 0)
        sub = Card("")
        sub.setStyleSheet("QFrame#card { background: transparent; border: none; }")
        sub.lay.setContentsMargins(0, 0, 0, 0)
        eye = self.check(sub, "鸟眼框", lambda: Fm().showEye, lambda vv: setattr(Fm(), "showEye", vv))
        self.visible_when(eye,lambda: not st.is_aircraft)
        self.check(sub, lambda: "机头框" if st.is_aircraft else "鸟头框", lambda: Fm().showHead, lambda vv: setattr(Fm(), "showHead", vv))
        self.check(sub, lambda: "机身框（含机翼）" if st.is_aircraft else "鸟身框（含展开的翅膀）", lambda: Fm().showBody, lambda vv: setattr(Fm(), "showBody", vv))
        self.check(sub, lambda: "机身框闪烁" if st.is_aircraft else "鸟身框闪烁", lambda: Fm().blinkBody, lambda vv: setattr(Fm(), "blinkBody", vv))
        self.combo(sub, "样式", [(x.title, x) for x in FocusMarkStyle], lambda: Fm().style, lambda vv: setattr(Fm(), "style", vv))
        for label, key in [("鸟眼颜色", "eyeColor"), ("鸟头颜色", "headColor"), ("鸟身颜色", "bodyColor")]:
            color = self.combo(sub, lambda k=key,l=label: ({"headColor":"机头颜色","bodyColor":"机身颜色"}.get(k,l) if st.is_aircraft else l), [(x.title, x) for x in FocusMarkColor], lambda k=key: getattr(Fm(), k), lambda vv, k=key: setattr(Fm(), k, vv))
            if key == "eyeColor":self.visible_when(color.row,lambda: not st.is_aircraft)
        self.slider(sub, lambda: "机身框大小" if st.is_aircraft else "鸟身框大小", lambda: Fm().bodySize, lambda vv: setattr(Fm(), "bodySize", vv), 0.5, 2.5, lambda x: f"{x:.1f}×")
        self.slider(sub, lambda: "机头框大小" if st.is_aircraft else "眼/头框大小", lambda: Fm().size, lambda vv: setattr(Fm(), "size", vv), 0.5, 2.5, lambda x: f"{x:.1f}×")
        self.slider(sub, "线宽", lambda: Fm().lineWidth, lambda vv: setattr(Fm(), "lineWidth", vv), 0.5, 3, lambda x: f"{x:.1f}×")
        hidden = self.check(sub, "鸟眼被遮挡时框住鸟头", lambda: Fm().headWhenHidden, lambda vv: setattr(Fm(), "headWhenHidden", vv))
        self.visible_when(hidden,lambda: not st.is_aircraft)
        v.addWidget(sub)
        card.add(box)
        self.visible_when(box, lambda: Fm().enabled)
        self.check(card, "快门闪烁边框", lambda: Fm().captureFlash, lambda vv: setattr(Fm(), "captureFlash", vv))
        color = self.combo(card, "边框颜色", [(x.title, x) for x in FocusMarkColor], lambda: Fm().captureColor, lambda vv: setattr(Fm(), "captureColor", vv))
        size = self.slider(card, "边框大小", lambda: Fm().captureSize, lambda vv: setattr(Fm(), "captureSize", vv), 0.25, 0.98, lambda x: f"{x * 100:.0f}%")
        self.visible_when(color, lambda: Fm().captureFlash)
        self.visible_when(size, lambda: Fm().captureFlash)
        rate = self.slider(card, "闪烁频率", lambda: Fm().flashRate, lambda vv: setattr(Fm(), "flashRate", vv),
                           1, 120, lambda x: f"{x:.0f} 次/秒", step=1)
        self.visible_when(rate, lambda: Fm().captureFlash or Fm().blinkBody)
        card.add(caption("视频帧率应至少为闪烁频率的 2 倍；过高频率可能显示为静止或较慢闪烁。"))
        return card

    def _music_card(self, choose_audio) -> Card:
        st = self.state
        A = lambda: st.audio   # noqa: E731
        card = Card("背景音乐", "♪")
        top = QHBoxLayout()
        name = QLabel()
        name.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Preferred)
        ch = QPushButton("选择音乐…")
        rm = QPushButton("移除")
        ch.clicked.connect(choose_audio)
        rm.clicked.connect(st.remove_audio)
        top.addWidget(name, 1)
        top.addWidget(ch)
        top.addWidget(rm)
        card.add(top)
        body = QWidget()
        bv = QVBoxLayout(body)
        bv.setContentsMargins(0, 0, 0, 0)
        sub = Card("")
        sub.setStyleSheet("QFrame#card { background: transparent; border: none; }")
        sub.lay.setContentsMargins(0, 0, 0, 0)

        def max_off():
            d = st.audio_overview[0] if st.audio_overview else 0.1
            vd = st.job.duration if st.job else 0
            return max(0.1, d - min(vd, d))
        off = self.slider(sub, "从音乐的", lambda: A().startOffset, lambda vv: setattr(A(), "startOffset", vv), 0, 600,
                          lambda x: f"{fmt_time(x)} 开始", topic="audio", tip="也可以在下方「音乐」轨道上拖动高亮区域")
        self.slider(sub, "音量", lambda: A().volume, lambda vv: setattr(A(), "volume", vv), 0, 1.5, lambda x: f"{x * 100:.0f}%", topic="audio")
        self.slider(sub, "淡入", lambda: A().fadeIn, lambda vv: setattr(A(), "fadeIn", vv), 0, 3, lambda x: f"{x:.1f} 秒", step=0.1, topic="audio")
        self.slider(sub, "淡出", lambda: A().fadeOut, lambda vv: setattr(A(), "fadeOut", vv), 0, 5, lambda x: f"{x:.1f} 秒", step=0.1, topic="audio")
        self.check(sub, "音乐比视频短时循环", lambda: A().loop, lambda vv: setattr(A(), "loop", vv), topic="audio")
        sub.add(caption("导出「视频」时会把音乐合成进去（AAC 256 kbps）。"))
        bv.addWidget(sub)
        card.add(body)
        hint = caption("支持 MP3 / M4A / WAV / AIFF / FLAC，也可以把音频文件拖到下方的「音乐」轨道。")
        card.add(hint)

        def ref():
            has = bool(A().path)
            name.setText(os.path.basename(A().path) if has else "")
            name.setVisible(has)
            rm.setVisible(has)
            ch.setText("更换…" if has else "选择音乐…")
            body.setVisible(has)
            hint.setVisible(not has)
            sl = off.findChild(QSlider)
            # rescale the offset slider to the song length
            mo = max_off()
            sl.blockSignals(True)
            sl.setValue(int(round(min(A().startOffset, mo) / mo * 1000)) if mo > 0 else 0)
            sl.blockSignals(False)
        self.b.add(ref)

        # offset slider works in fractions of the usable range
        sl = off.findChild(QSlider)
        val = [w for w in off.findChildren(QLabel) if w.objectName() == "value"][0]
        try:
            sl.valueChanged.disconnect()
        except Exception:
            pass

        def off_changed(k):
            A().startOffset = max_off() * k / 1000
            val.setText(f"{fmt_time(A().startOffset)} 开始")
            st.audio_settings_changed()
        sl.valueChanged.connect(off_changed)
        return card

    def _watermark_card(self, choose_watermark) -> Card:
        st = self.state
        W = lambda: st.watermark   # noqa: E731
        card = Card("图片水印", "✍")
        top = QHBoxLayout()
        thumb = QLabel()
        thumb.setFixedSize(96, 44)
        thumb.setAlignment(Qt.AlignCenter)
        thumb.setStyleSheet("background: rgba(0,0,0,0.35); border-radius: 6px;")
        top.addWidget(thumb)
        col = QVBoxLayout()
        en = QCheckBox("导出时添加")
        en.toggled.connect(lambda on: (setattr(W(), "enabled", on), st.watermark_changed()))
        chb = QPushButton("导入 PNG…")
        chb.clicked.connect(choose_watermark)
        col.addWidget(en)
        col.addWidget(chb)
        top.addLayout(col, 1)
        card.add(top)
        body = QWidget()
        bv = QVBoxLayout(body)
        bv.setContentsMargins(0, 0, 0, 0)
        sub = Card("")
        sub.setStyleSheet("QFrame#card { background: transparent; border: none; }")
        sub.lay.setContentsMargins(0, 0, 0, 0)
        self.slider(sub, "大小", lambda: W().size, lambda v: setattr(W(), "size", v), 0.05, 1.0, lambda v: f"{v * 100:.0f}%",
                    topic="watermark", tip="水印宽度占成片短边的比例")
        self.slider(sub, "不透明度", lambda: W().opacity, lambda v: setattr(W(), "opacity", v), 0.1, 1.0, lambda v: f"{v * 100:.0f}%", topic="watermark")
        gr = QHBoxLayout()
        grid = QGridLayout()
        grid.setSpacing(3)
        self.wm_cells = []
        for r in range(3):
            for cc in range(3):
                b = QPushButton()
                b.setFixedSize(20, 14)
                b.setCheckable(True)
                b.setStyleSheet("QPushButton { padding: 0; border-radius: 3px; background: rgba(255,255,255,0.12); }"
                                f"QPushButton:checked {{ background: {theme.hexa(theme.ACCENT)}; }}")
                b.clicked.connect(lambda _=False, r=r, cc=cc: self._place_watermark(r, cc))
                grid.addWidget(b, r, cc)
                self.wm_cells.append((b, r, cc))
        gr.addLayout(grid)
        gr.addWidget(caption("快速放到角落或居中；在「成片预览」里可以直接拖动水印到任意位置。"), 1)
        sub.add(gr)
        bv.addWidget(sub)
        card.add(body)
        hint = caption("例如你的签名或 Logo。建议用透明背景的 PNG。导入后可以在成片预览里拖动位置、调整大小。")
        card.add(hint)

        def ref():
            q = st.watermark_qimage
            has = q is not None
            if has:
                thumb.setPixmap(QPixmap.fromImage(q).scaled(QSize(90, 40), Qt.KeepAspectRatio, Qt.SmoothTransformation))
            thumb.setVisible(has)
            en.setVisible(has)
            en.blockSignals(True)
            en.setChecked(W().enabled)
            en.blockSignals(False)
            chb.setText("更换图片…" if has else "导入 PNG…")
            body.setVisible(has and W().enabled)
            hint.setVisible(not has)
            pos = self._grid_positions()
            for b, r, cc in self.wm_cells:
                xs, ys = pos
                b.setChecked(abs(W().centerX - xs[cc]) < 0.01 and abs(W().centerY - ys[r]) < 0.01)
        self.b.add(ref)
        return card

    def _grid_positions(self):
        st = self.state
        q = st.watermark_qimage
        Wd, Hd = st.export.output_size
        short = min(Wd, Hd)
        wN = st.watermark.size * short / Wd
        hN = st.watermark.size * short * (q.height() / max(1, q.width()) if q else 0.3) / Hd
        mx, my = 0.035 * short / Wd, 0.035 * short / Hd
        return [mx + wN / 2, 0.5, 1 - mx - wN / 2], [my + hN / 2, 0.5, 1 - my - hN / 2]

    def _place_watermark(self, r, cc):
        xs, ys = self._grid_positions()
        self.state.watermark.centerX, self.state.watermark.centerY = xs[cc], ys[r]
        self.state.watermark_changed()


class Inspector(QWidget):
    def __init__(self, state, choose_audio, choose_watermark, on_export):
        super().__init__()
        self.state = state
        self.setObjectName("panel")
        self.setFixedWidth(340)
        v = QVBoxLayout(self)
        v.setContentsMargins(0, 8, 0, 0)
        v.setSpacing(0)
        self.tabbar = QTabBar()
        self.tabbar.setExpanding(True)
        for t in ("构图", "画面", "输出"):
            self.tabbar.addTab(t)
        v.addWidget(self.tabbar)
        self.tabs = [ComposeTab(state), LookTab(state), OutputTab(state, choose_audio, choose_watermark)]
        # QStackedWidget manages show/hide + re-layout of the pages; plain setVisible leaves
        # scroll-area geometry stale when switching back (overlapping controls)
        self.stack = QStackedWidget()
        for t in self.tabs:
            self.stack.addWidget(t)
        v.addWidget(self.stack, 1)
        self.tabbar.currentChanged.connect(self._tab)
        foot = QFrame()
        foot.setObjectName("panel")
        fl = QHBoxLayout(foot)
        fl.setContentsMargins(12, 8, 12, 10)
        col = QVBoxLayout()
        col.setSpacing(1)
        self.sum1 = QLabel()
        self.sum1.setStyleSheet("font-weight: 600; font-size: 12px;")
        self.sum2 = caption("")
        col.addWidget(self.sum1)
        col.addWidget(self.sum2)
        fl.addLayout(col, 1)
        exp = QPushButton("导出…")
        exp.setObjectName("primary")
        exp.clicked.connect(on_export)
        fl.addWidget(exp)
        v.addWidget(foot)
        self.tabbar.setCurrentIndex(getattr(state, "inspector_tab", 0))
        self._tab(self.tabbar.currentIndex())
        state.changed.connect(self._changed)
        self.refresh()

    def _tab(self, k):
        self.stack.setCurrentIndex(k)
        cur = self.tabs[k]
        self.state.inspector_tab = k
        self.state.save_settings()
        # QScrollArea's widgetResizable stops tracking after a page is hidden/shown: the body
        # keeps its sizeHint width and overflows. Force it back to the viewport width once shown.
        QTimer.singleShot(0, lambda: self._relayout_tab(cur))

    @staticmethod
    def _relayout_tab(cur: "Tab"):
        vp = cur.viewport()
        w = cur.widget()
        if vp.width() > 0 and w.width() != vp.width():
            w.resize(vp.width(), w.height())

    def _changed(self, topic):
        if topic in ("frame", "preview", "source", "progress", "playing", "zoom"):
            return
        self.refresh()

    def refresh(self):
        for t in self.tabs:
            t.b.refresh()
        job = self.state.job
        if job:
            W, H = job.output_size
            self.sum1.setText(f"{W}×{H} · {job.export.outputFPS:g} fps · {job.duration:.1f} 秒")
            extra = (" · ♪" if (self.state.job.mixed_audio(self.state.audio).active if self.state.job else self.state.audio.active) else "") + (" · 水印" if self.state.watermark.active else "")
            self.sum2.setText(job.export.codec.title.split("（")[0] + extra)
