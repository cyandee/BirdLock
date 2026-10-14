"""Main window, menus, export dialog, user agreement and documents (port of ContentView / ExportSheet / LegalViews)."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from PySide6.QtCore import QSize, Qt, QUrl
from PySide6.QtGui import QAction, QDesktopServices, QIcon, QKeySequence
from PySide6.QtWidgets import (QButtonGroup, QCheckBox, QComboBox, QDialog, QFileDialog, QFrame, QGridLayout, QHBoxLayout,
                               QLabel, QMainWindow, QMessageBox, QProgressBar, QPushButton, QSizePolicy, QTextBrowser,
                               QVBoxLayout, QWidget)

from . import theme
from .inspector import Inspector
from .preview import PreviewArea
from .state import AppState, is_audio_file
from .timeline import TimelinePanel, fmt_time
from .. import APP_NAME, CONTACT_EMAIL, __version__
from ..core import frames as F
from ..core.paths import IS_WINDOWS, data_dir, docs_dir

AGREEMENT_VERSION = "1.0"
PHOTO_FILTER = "照片 (*.jpg *.jpeg *.heic *.heif *.hif *.png *.tif *.tiff)"
AUDIO_FILTER = "音频 (*.mp3 *.m4a *.aac *.wav *.aif *.aiff *.flac *.ogg *.wma *.mp4 *.mov *.m4v)"


def reveal(path: str):
    if IS_WINDOWS:
        subprocess.Popen(["explorer", "/select,", os.path.normpath(path)])
    elif sys.platform == "darwin":
        subprocess.Popen(["open", "-R", path])
    else:
        QDesktopServices.openUrl(QUrl.fromLocalFile(os.path.dirname(path)))


def doc_text(name: str) -> str:
    """Bundled document; the Windows build has its own variants in docs/windows/."""
    for d in (docs_dir() / "windows", docs_dir()):
        p = d / name
        if p.exists():
            return p.read_text(encoding="utf-8")
    return f"（找不到 {name}）"


def agreement_text() -> str:
    t = doc_text("用户协议.md")
    # storage locations of this version
    t = t.replace("`~/Library/Caches/BirdLock`", f"`{data_dir() / 'cache'}`")
    t = t.replace("`~/Library/Application Support/BirdLock`", f"`{data_dir() / 'watermarks'}`")
    return hard_breaks(t.replace("Mac 电脑", "电脑"))


def hard_breaks(md: str) -> str:
    """Keep single line breaks (Qt's Markdown would join consecutive lines into one paragraph)."""
    out = []
    lines = md.split("\n")
    for k, line in enumerate(lines):
        nxt = lines[k + 1].lstrip() if k + 1 < len(lines) else ""
        if line.strip() and nxt and not line.startswith(("#", "|", "```")) and not nxt.startswith(("-", "*", "|", "#")) \
                and not nxt.split(" ")[0].rstrip(".").isdigit():
            line += "  "
        out.append(line)
    return "\n".join(out)


class DocDialog(QDialog):
    def __init__(self, title: str, markdown: str, parent=None, buttons=None):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.resize(700, 640)
        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        tb = QTextBrowser()
        tb.setOpenExternalLinks(True)
        tb.setStyleSheet("QTextBrowser { background: #1c1d20; border: none; padding: 18px; font-size: 13px; }")
        tb.setMarkdown(markdown)
        v.addWidget(tb, 1)
        if buttons:
            v.addWidget(buttons)


class AgreementDialog(QDialog):
    """Shown on first launch; the app is usable only after agreeing."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("用户协议")
        self.setModal(True)
        self.resize(680, 620)
        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(0)
        head = QFrame()
        head.setObjectName("panel")
        hl = QHBoxLayout(head)
        hl.setContentsMargins(18, 14, 18, 14)
        icon = QLabel("🐦")
        icon.setStyleSheet("font-size: 24px;")
        hl.addWidget(icon)
        col = QVBoxLayout()
        t = QLabel(f"欢迎使用 {APP_NAME}")
        t.setStyleSheet("font-size: 15px; font-weight: 600;")
        s = QLabel("使用前请阅读用户协议，特别是加粗的免责条款")
        s.setObjectName("caption")
        col.addWidget(t)
        col.addWidget(s)
        hl.addLayout(col, 1)
        v.addWidget(head)
        tb = QTextBrowser()
        tb.setStyleSheet("QTextBrowser { background: #1c1d20; border: none; padding: 18px; font-size: 13px; }")
        tb.setMarkdown(agreement_text())
        v.addWidget(tb, 1)
        foot = QFrame()
        foot.setObjectName("panel")
        fl = QHBoxLayout(foot)
        fl.setContentsMargins(14, 10, 14, 12)
        lic = QPushButton("查看开源许可")
        lic.setObjectName("link")
        lic.clicked.connect(lambda: show_licenses(self))
        fl.addWidget(lic)
        fl.addStretch(1)
        no = QPushButton("不同意")
        yes = QPushButton("同意并继续")
        yes.setObjectName("primary")
        yes.setDefault(True)
        no.clicked.connect(self.reject)
        yes.clicked.connect(self.accept)
        fl.addWidget(no)
        fl.addWidget(yes)
        v.addWidget(foot)


def show_licenses(parent):
    text = doc_text("第三方许可.md")
    lic = docs_dir().parent / "LICENSE" if not (docs_dir() / "LICENSE").exists() else docs_dir() / "LICENSE"
    if lic.exists():
        text += "\n\n```\n" + lic.read_text(encoding="utf-8") + "\n```\n"
    DocDialog("许可与第三方组件", text, parent).exec()


class ExportDialog(QDialog):
    def __init__(self, state: AppState, parent=None):
        super().__init__(parent)
        self.state = state
        self.setWindowTitle("导出")
        self.setFixedWidth(500)
        v = QVBoxLayout(self)
        v.setContentsMargins(22, 20, 22, 18)
        v.setSpacing(14)
        t = QLabel("导出")
        t.setStyleSheet("font-size: 20px; font-weight: 600;")
        v.addWidget(t)
        kinds = QHBoxLayout()
        self.group = QButtonGroup(self)
        self.kind = "video"
        for k, title in (("video", "视频"), ("images", "对齐后的图片序列"), ("gif", "GIF 动图")):
            b = QPushButton(title)
            b.setCheckable(True)
            b.setChecked(k == "video")
            b.clicked.connect(lambda _=False, k=k: self._set_kind(k))
            self.group.addButton(b)
            kinds.addWidget(b)
        v.addLayout(kinds)
        self.grid = QGridLayout()
        self.grid.setHorizontalSpacing(14)
        self.grid.setVerticalSpacing(6)
        v.addLayout(self.grid)
        self.full = QCheckBox("使用原图全分辨率渲染（推荐，较慢）")
        self.full.toggled.connect(lambda on: (setattr(state.export, "useFullResolution", on), state.save_settings()))
        v.addWidget(self.full)
        self.bar = QProgressBar()
        self.bar.setRange(0, 1000)
        self.bar.setTextVisible(False)
        self.bar.setFixedHeight(6)
        v.addWidget(self.bar)
        msg_row = QHBoxLayout()
        self.msg = QLabel()
        self.msg.setObjectName("caption")
        self.msg.setWordWrap(True)
        self.reveal_btn = QPushButton("在文件夹中显示")
        self.open_btn = QPushButton("打开")
        self.reveal_btn.clicked.connect(lambda: reveal(state.export_path))
        self.open_btn.clicked.connect(lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(state.export_path)))
        msg_row.addWidget(self.msg, 1)
        msg_row.addWidget(self.reveal_btn)
        msg_row.addWidget(self.open_btn)
        v.addLayout(msg_row)
        btns = QHBoxLayout()
        btns.addStretch(1)
        self.cancel_btn = QPushButton("取消导出")
        self.close_btn = QPushButton("关闭")
        self.go_btn = QPushButton("选择位置并导出…")
        self.go_btn.setObjectName("primary")
        self.cancel_btn.clicked.connect(state.cancel_export)
        self.close_btn.clicked.connect(self._close)
        self.go_btn.clicked.connect(self._choose)
        for b in (self.cancel_btn, self.close_btn, self.go_btn):
            btns.addWidget(b)
        v.addLayout(btns)
        state.changed.connect(self._changed)
        self.refresh()

    def _set_kind(self, k):
        self.kind = k
        self.refresh()

    def _changed(self, topic):
        if topic in ("export", "job", "audio", "watermark"):
            self.refresh()

    def _close(self):
        st = self.state
        st.export_message, st.export_progress = "", 0.0
        self.accept()

    def refresh(self):
        st = self.state
        job = st.job
        while self.grid.count():
            w = self.grid.takeAt(0).widget()
            if w:
                w.deleteLater()
        rows = []
        if job:
            W, H = job.output_size
            rows.append(("尺寸", f"{W} × {H}（{job.export.aspect.label}）"))
            if self.kind == "video":
                rows.append(("时长", f"{job.duration:.1f} 秒，{len(job.output_frames)} 帧 @ {job.export.outputFPS:g} fps"))
                rows.append(("编码", job.export.codec.title))
                rows.append(("音乐", f"{Path(st.audio.path).stem}（从 {fmt_time(st.audio.startOffset)} 开始）" if st.audio.active else "无"))
            elif self.kind == "images":
                rows.append(("图片", f"{len(job.used)} 张 JPEG（对齐裁剪后）"))
            else:
                rows.append(("GIF", f"{len(job.output_frames)} 帧，最长边 720 px"))
            rows.append(("来源", f"使用 {len(job.used)} / {job.analysis.count} 张原图"))
            rows.append(("水印", "图片水印" if st.watermark.active else "无"))
        for r, (k, val) in enumerate(rows):
            a, b = QLabel(k), QLabel(val)
            a.setObjectName("caption")
            self.grid.addWidget(a, r, 0)
            self.grid.addWidget(b, r, 1)
        self.full.blockSignals(True)
        self.full.setChecked(st.export.useFullResolution)
        self.full.blockSignals(False)
        running = st.export_running
        for b in self.group.buttons():
            b.setEnabled(not running)
        self.full.setEnabled(not running)
        show = running or st.export_progress > 0 or bool(st.export_message)
        self.bar.setVisible(show)
        self.bar.setValue(int(st.export_progress * 1000))
        self.msg.setVisible(show)
        self.msg.setText(f"正在导出… {st.export_progress * 100:.0f}%" if running else st.export_message)
        done = not running and st.export_progress >= 1 and bool(st.export_path)
        self.reveal_btn.setVisible(done)
        self.open_btn.setVisible(done and self.kind != "images")
        self.cancel_btn.setVisible(running)
        self.close_btn.setVisible(not running)
        self.go_btn.setVisible(not running)

    def _default_name(self) -> str:
        a = self.state.analysis
        base = Path(a.frames[0].path).stem if a and a.frames else "BirdLock"
        return f"{base}_鸟眼锁定"

    def _start_dir(self) -> str:
        a = self.state.analysis
        return str(Path(a.frames[0].path).parent) if a and a.frames else str(Path.home())

    def _choose(self):
        st = self.state
        if st.job is None:
            return
        if self.kind == "images":
            d = QFileDialog.getExistingDirectory(self, "导出到此文件夹", self._start_dir())
            if d:
                st.export_to("images", str(Path(d) / self._default_name()))
            return
        ext = "gif" if self.kind == "gif" else st.export.codec.ext
        filt = "GIF (*.gif)" if ext == "gif" else ("MP4 视频 (*.mp4)" if ext == "mp4" else "MOV 视频 (*.mov)")
        path, _ = QFileDialog.getSaveFileName(self, "导出", str(Path(self._start_dir()) / f"{self._default_name()}.{ext}"), filt)
        if path:
            if not path.lower().endswith("." + ext):
                path += "." + ext
            st.export_to(self.kind, path)


class MainWindow(QMainWindow):
    def __init__(self, state: AppState):
        super().__init__()
        self.state = state
        self.setWindowTitle(APP_NAME)
        self.setMinimumSize(1100, 720)
        self.resize(1360, 860)
        self.setAcceptDrops(True)
        self._build_toolbar()
        central = QWidget()
        central.setObjectName("canvas")
        h = QHBoxLayout(central)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(0)
        left = QVBoxLayout()
        left.setSpacing(0)
        self.preview = PreviewArea(state, self.choose_photos)
        left.addWidget(self.preview, 1)
        from .timeline import TransportBar
        self.transport = TransportBar(state)
        left.addWidget(self.transport)
        self.timeline = TimelinePanel(state, self.choose_audio)
        left.addWidget(self.timeline)
        h.addLayout(left, 1)
        self.inspector = Inspector(state, self.choose_audio, self.choose_watermark, self.show_export)
        h.addWidget(self.inspector)
        self.setCentralWidget(central)
        self._build_menus()
        state.changed.connect(self._changed)
        self._changed("phase")

    # ---------------------------------------------------------------- chrome

    def _build_toolbar(self):
        tb = self.addToolBar("main")
        tb.setMovable(False)
        tb.setStyleSheet(f"QToolBar {{ background: {theme.hexa(theme.PANEL)}; border: none; padding: 6px 10px; spacing: 8px; }}")
        imp = QPushButton("🖼 导入")
        imp.setToolTip("导入连拍照片（文件夹或多张 JPG / HEIF）  Ctrl+O")
        imp.clicked.connect(self.choose_photos)
        tb.addWidget(imp)
        self.seg_combo = QComboBox()
        self.seg_combo.setToolTip("文件夹里检测到多组连拍，选择要处理的一组")
        self.seg_combo.currentIndexChanged.connect(lambda k: self.state.select_segment(k) if k >= 0 else None)
        self.seg_action = tb.addWidget(self.seg_combo)
        sp = QWidget()
        sp.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Preferred)
        tb.addWidget(sp)
        self.view_group = QButtonGroup(self)
        self.view_btns = {}
        box = QWidget()
        bl = QHBoxLayout(box)
        bl.setContentsMargins(0, 0, 0, 0)
        bl.setSpacing(0)
        for k, title in (("output", "成片预览"), ("source", "原图+识别")):
            b = QPushButton(title)
            b.setCheckable(True)
            b.setFixedWidth(100)
            b.setToolTip("Ctrl+T 切换")
            b.clicked.connect(lambda _=False, k=k: self.set_view(k))
            self.view_group.addButton(b)
            bl.addWidget(b)
            self.view_btns[k] = b
        self.view_box = tb.addWidget(box)
        sp2 = QWidget()
        sp2.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Preferred)
        tb.addWidget(sp2)
        self.export_btn = QPushButton("⇪ 导出")
        self.export_btn.setToolTip("导出视频 / 图片序列 / GIF  Ctrl+E")
        self.export_btn.clicked.connect(self.show_export)
        self.export_action = tb.addWidget(self.export_btn)

    def _build_menus(self):
        mb = self.menuBar()
        st = self.state

        def act(menu, title, fn, key=None):
            a = QAction(title, self)
            if key:
                a.setShortcut(QKeySequence(key))
                a.setShortcutContext(Qt.WindowShortcut)
            a.triggered.connect(fn)
            menu.addAction(a)
            return a

        m = mb.addMenu("文件")
        act(m, "导入连拍文件夹…", self.choose_photos, "Ctrl+O")
        act(m, "导入照片文件…", self.choose_photo_files, "Ctrl+Shift+O")
        self.a_export = act(m, "导出…", self.show_export, "Ctrl+E")
        m.addSeparator()
        act(m, "添加背景音乐…", self.choose_audio)
        act(m, "导入图片水印…", self.choose_watermark)
        m.addSeparator()
        act(m, "打开数据文件夹（设置、缓存、日志）", lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(str(data_dir()))))
        act(m, "清空缓存…", self.clear_cache)
        m.addSeparator()
        act(m, "退出", self.close, "Ctrl+Q")
        m = mb.addMenu("播放")
        act(m, "播放 / 暂停", st.toggle_play, "Space")
        act(m, "上一帧", lambda: st.step(-1), "Left")
        act(m, "下一帧", lambda: st.step(1), "Right")
        m.addSeparator()
        act(m, "切换 成片 / 原图", lambda: self.set_view("source" if st.view_mode == "output" else "output"), "Ctrl+T")
        act(m, "排除 / 恢复当前帧", st.toggle_excluded, "X")
        m = mb.addMenu("修正")
        act(m, "修正鸟眼", self._toggle_fix, "E")
        act(m, "上一个推算帧", lambda: st.jump_to_predicted(-1), "[")
        act(m, "下一个推算帧", lambda: st.jump_to_predicted(1), "]")
        act(m, "撤销本帧修正", lambda: st.clear_manual_eye())
        m.addSeparator()
        act(m, "原图放大 / 全图", self._toggle_zoom, "Z")
        m = mb.addMenu("帮助")
        act(m, "BirdLock 使用说明", self.open_manual, "F1")
        act(m, "反馈意见（发邮件）", lambda: QDesktopServices.openUrl(QUrl(f"mailto:{CONTACT_EMAIL}?subject=BirdLock%20意见反馈")))
        m.addSeparator()
        act(m, "用户协议…", lambda: DocDialog("用户协议", agreement_text(), self).exec())
        act(m, "许可与第三方组件…", lambda: show_licenses(self))
        act(m, f"关于 {APP_NAME}", self.about)

    def _changed(self, topic):
        st = self.state
        has = st.analysis is not None
        self.view_box.setVisible(has)
        self.export_action.setVisible(has)
        self.transport.setVisible(has)
        self.timeline.setVisible(has)
        self.inspector.setVisible(has)
        self.a_export.setEnabled(st.job is not None)
        for k, b in self.view_btns.items():
            b.setChecked(st.view_mode == k)
        if topic in ("frames", "phase"):
            segs = st.segments
            self.seg_action.setVisible(len(segs) > 1)
            self.seg_combo.blockSignals(True)
            self.seg_combo.clear()
            for k, s in enumerate(segs):
                self.seg_combo.addItem(f"第 {k + 1} 组 · {s.count} 张")
            if 0 <= st.segment_index < len(segs):
                self.seg_combo.setCurrentIndex(st.segment_index)
            self.seg_combo.blockSignals(False)

    # ---------------------------------------------------------------- actions

    def set_view(self, k):
        self.state.view_mode = k
        self.state.changed.emit("view")
        self.state.refresh_preview()

    def _toggle_fix(self):
        st = self.state
        if st.view_mode == "source" and st.source_tool == "fixEye":
            st.source_tool = "none"
            st.changed.emit("tool")
        else:
            st.start_fixing_eye()

    def _toggle_zoom(self):
        st = self.state
        if st.view_mode != "source":
            self.set_view("source")
        st.source_zoom = 1.0 if st.source_zoom > 1.01 else 4.0
        st.changed.emit("zoom")

    def choose_photos(self):
        d = QFileDialog.getExistingDirectory(self, "选择连拍照片所在的文件夹")
        if d:
            self.state.import_paths([d])

    def choose_photo_files(self):
        files, _ = QFileDialog.getOpenFileNames(self, "选择连拍照片（可多选）", "", PHOTO_FILTER)
        if files:
            self.state.import_paths(files)

    def choose_audio(self):
        p, _ = QFileDialog.getOpenFileName(self, "选择背景音乐", "", AUDIO_FILTER)
        if p:
            self.state.set_audio(p)

    def choose_watermark(self):
        p, _ = QFileDialog.getOpenFileName(self, "选择水印图片（推荐带透明背景的 PNG）", "", "图片 (*.png *.tif *.tiff *.jpg *.jpeg *.webp)")
        if p:
            self.state.set_watermark_file(p)

    def show_export(self):
        if self.state.job is None:
            return
        ExportDialog(self.state, self).exec()

    def open_manual(self):
        for name in ("使用说明.pdf", "使用说明.html"):
            for d in (docs_dir() / "windows", docs_dir()):
                p = d / name
                if p.exists():
                    QDesktopServices.openUrl(QUrl.fromLocalFile(str(p)))
                    return
        DocDialog("使用说明", doc_text("使用说明.md"), self).exec()

    def about(self):
        QMessageBox.about(self, f"关于 {APP_NAME}",
                          f"<h3>{APP_NAME}</h3><p>版本 {__version__} 测试版（Windows）</p>"
                          "<p>飞鸟连拍对齐鸟眼，一键生成连拍视频。</p>"
                          f"<p>Copyright © 2026 cyanol<br>依据 GNU AGPL-3.0 开源<br>"
                          f"源代码：<a href='https://github.com/cyandee/BirdLock'>github.com/cyandee/BirdLock</a><br>"
                          f"联系：<a href='mailto:{CONTACT_EMAIL}'>{CONTACT_EMAIL}</a></p>")

    def clear_cache(self):
        size = self.state.cache.total_size() / (1 << 20)
        if QMessageBox.question(self, "清空缓存", f"缓存占用约 {size:.0f} MB（缩略图和分析结果）。\n清空后再打开同一组照片需要重新分析。确定清空？") \
                == QMessageBox.Yes:
            self.state.cache.clear()

    # ---------------------------------------------------------------- drag & drop

    def dragEnterEvent(self, ev):
        if ev.mimeData().hasUrls():
            ev.acceptProposedAction()
            self.preview.drop.set_targeted(True)

    def dragLeaveEvent(self, _):
        self.preview.drop.set_targeted(False)

    def dropEvent(self, ev):
        self.preview.drop.set_targeted(False)
        paths = [u.toLocalFile() for u in ev.mimeData().urls() if u.isLocalFile()]
        self.open_paths(paths)

    def open_paths(self, paths: list[str]):
        if not paths:
            return
        audio = [p for p in paths if is_audio_file(p)]
        if audio and len(audio) == len(paths) and self.state.analysis is not None:
            self.state.set_audio(audio[0])
        else:
            self.state.import_paths([p for p in paths if not is_audio_file(p)])

    def closeEvent(self, ev):
        self.state.stop()
        self.state._save_settings_now()
        super().closeEvent(ev)
