"""Main window, menus, export dialog, user agreement and documents (port of ContentView / ExportSheet / LegalViews)."""
from __future__ import annotations

import os
import subprocess
import sys
import threading
from pathlib import Path

from PySide6.QtCore import QSize, Qt, QUrl, Signal
from PySide6.QtGui import QAction, QDesktopServices, QIcon, QImage, QKeySequence, QPixmap
from PySide6.QtWidgets import (QButtonGroup, QCheckBox, QComboBox, QDialog, QFileDialog, QFrame, QGridLayout,
                               QHBoxLayout, QLabel, QListWidget, QListWidgetItem, QMainWindow, QMessageBox,
                               QProgressBar, QPushButton, QSizePolicy, QTextBrowser, QVBoxLayout, QWidget)

from . import theme
from .inspector import Inspector
from .preview import PreviewArea
from .state import AppState, is_audio_file, to_qimage
from .timeline import TimelinePanel, fmt_time
from .. import APP_NAME, CONTACT_EMAIL, CONTACT_TEXT, __version__
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


class ImportPreviewDialog(QDialog):
    """Shows the photos found in the chosen folder (with thumbnails and checkboxes) before importing,
    so it is always clear what will be imported."""

    _thumb_ready = Signal(int, QImage)

    def __init__(self, folder: str, parent=None):
        super().__init__(parent)
        self.folder = folder
        self.files = F.collect_image_paths([folder])
        self._stop = threading.Event()
        self.setWindowTitle("确认要导入的照片")
        self.resize(880, 640)
        v = QVBoxLayout(self)
        v.setContentsMargins(16, 14, 16, 12)
        v.setSpacing(10)
        head = QVBoxLayout()
        self.title = QLabel()
        self.title.setStyleSheet("font-size: 15px; font-weight: 600;")
        self.sub = QLabel()
        self.sub.setObjectName("caption")
        self.sub.setWordWrap(True)
        head.addWidget(self.title)
        head.addWidget(self.sub)
        v.addLayout(head)
        self.merge_groups = QCheckBox("归为一组，合成同一视频（不勾选则按拍摄间隔分组）")
        v.addWidget(self.merge_groups)
        self.list = QListWidget()
        self.list.setViewMode(QListWidget.IconMode)
        self.list.setIconSize(QSize(96, 96))
        self.list.setResizeMode(QListWidget.Adjust)
        self.list.setUniformItemSizes(True)
        self.list.setSpacing(6)
        self.list.setObjectName("importList")
        self.list.setStyleSheet("QListWidget#importList { background: #1c1d20; border: 1px solid rgba(255,255,255,0.08);"
                                " border-radius: 8px; }")
        v.addWidget(self.list, 1)
        btns = QHBoxLayout()
        all_b = QPushButton("全选")
        none_b = QPushButton("全不选")
        all_b.clicked.connect(lambda: self._set_all(True))
        none_b.clicked.connect(lambda: self._set_all(False))
        btns.addWidget(all_b)
        btns.addWidget(none_b)
        btns.addStretch(1)
        cancel = QPushButton("取消")
        self.go = QPushButton("导入所选照片…")
        self.go.setObjectName("primary")
        self.go.clicked.connect(self.accept)
        cancel.clicked.connect(self.reject)
        btns.addWidget(cancel)
        btns.addWidget(self.go)
        v.addLayout(btns)
        self._thumb_ready.connect(self._add_thumb)
        self._fill()

    def _fill(self):
        n = len(self.files)
        if not n:
            self.title.setText("这个文件夹里没有找到照片")
            self.sub.setText("支持 JPG / JPEG / HEIC / HEIF / HIF / PNG / TIFF（也会查找子文件夹）。\n"
                             "如果照片在别处，请重新选择文件夹。")
            self.list.hide()
            self.go.hide()
            self.resize(560, 220)
            return
        self.title.setText(f"找到 {n} 张照片")
        self.sub.setText(self.folder)
        for k, p in enumerate(self.files):
            it = QListWidgetItem(os.path.basename(p))
            it.setFlags(it.flags() | Qt.ItemIsUserCheckable)
            it.setCheckState(Qt.Checked)
            it.setToolTip(p)
            it.setTextAlignment(Qt.AlignHCenter | Qt.AlignBottom)
            self.list.addItem(it)
        self._update_count()
        self.list.itemChanged.connect(lambda _it: self._update_count())
        threading.Thread(target=self._load_thumbs, daemon=True).start()

    def _load_thumbs(self):
        for k, p in enumerate(self.files):
            if self._stop.is_set() or k >= 600:     # thumbnails for the first few hundred are enough
                return
            img = F.load_thumbnail(p)
            if img is not None:
                self._thumb_ready.emit(k, to_qimage(img))

    def _add_thumb(self, k: int, im: QImage):
        if self._stop.is_set() or k >= self.list.count():
            return
        it = self.list.item(k)
        if it is not None and it.icon().isNull():
            it.setIcon(QPixmap.fromImage(im))

    def _set_all(self, on: bool):
        for k in range(self.list.count()):
            self.list.item(k).setCheckState(Qt.Checked if on else Qt.Unchecked)

    def _update_count(self):
        n = sum(1 for k in range(self.list.count()) if self.list.item(k).checkState() == Qt.Checked)
        self.go.setText(f"导入所选照片（{n} 张）")
        self.go.setEnabled(n > 0)

    @property
    def selected(self) -> list[str]:
        return [self.files[k] for k in range(min(self.list.count(), len(self.files)))
                if self.list.item(k).checkState() == Qt.Checked]

    def reject(self):
        self._stop.set()
        super().reject()


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

    def reject(self):
        # The title-bar close button must not leave an invisible encoder running.
        if self.state.export_running:
            self.state.cancel_export()
        super().reject()

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
                mix = job.mixed_audio(st.audio)
                rows.append(("音频", f"{len(mix.arranged_tracks)} 段音频（含启用的特写快门）" if mix.active else "无"))
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
        stopping = running and st._export_cancel.cancelled
        self.msg.setText("正在取消导出…" if stopping else
                         (f"正在导出… {st.export_progress * 100:.0f}%" if running else st.export_message))
        done = not running and st.export_progress >= 1 and bool(st.export_path)
        self.reveal_btn.setVisible(done)
        self.open_btn.setVisible(done and self.kind != "images")
        self.cancel_btn.setVisible(running)
        self.cancel_btn.setEnabled(not stopping)
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
        self.subject_combo = QComboBox()
        self.subject_combo.addItem("鸟类","bird");self.subject_combo.addItem("飞机（试验）","aircraft")
        self.subject_combo.setToolTip("飞机自动识别机头和机身；复杂视角请检查，可逐帧修正。首次分析较慢。")
        self.subject_combo.currentIndexChanged.connect(lambda k: self.state.change_subject(self.subject_combo.itemData(k)) if k >= 0 else None)
        tb.addWidget(self.subject_combo)
        self.seg_combo = QComboBox()
        self.seg_combo.setToolTip("文件夹里检测到多组连拍，选择要处理的一组")
        self.seg_combo.currentIndexChanged.connect(lambda k: self.state.select_segment(self.seg_combo.itemData(k)) if k >= 0 else None)
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
        self.support_btn = QPushButton("☕ 请作者喝杯咖啡")
        self.support_btn.clicked.connect(self.support)
        tb.addWidget(self.support_btn)

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
        act(m, "反馈与交流（邮箱）", self.contact)
        act(m, "导出诊断日志…", self.export_diagnostics)
        m.addSeparator()
        act(m, "用户协议…", lambda: DocDialog("用户协议", agreement_text(), self).exec())
        act(m, "许可与第三方组件…", lambda: show_licenses(self))
        act(m, f"关于 {APP_NAME}", self.about)
        act(mb, "☕ 赞赏", self.support)

    def export_diagnostics(self):
        from ..core.diagnostics import export_bundle
        path, _ = QFileDialog.getSaveFileName(self, "导出诊断日志", "BirdLock-诊断日志.zip", "ZIP (*.zip)")
        if not path:
            return
        try:
            export_bundle(path if path.lower().endswith('.zip') else path+'.zip')
            QMessageBox.information(self, "诊断日志", "日志已保存，可直接发给作者。发送前也可以解压检查内容。")
        except Exception as error:
            QMessageBox.warning(self, "保存失败", str(error))

    def _changed(self, topic):
        st = self.state
        has = st.analysis is not None
        self.subject_combo.blockSignals(True)
        self.subject_combo.setCurrentIndex(self.subject_combo.findData(st.subject))
        self.subject_combo.setEnabled(not st.export_running and st.phase != "importing")
        self.subject_combo.blockSignals(False)
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
            self.seg_combo.addItem("合并选中组 → 同一视频", -1)
            for k, s in enumerate(segs):
                self.seg_combo.addItem(f"第 {k + 1} 组 · {s.count} 张", k)
            self.seg_combo.setCurrentIndex(self.seg_combo.findData(st.segment_index))
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
        # the native Windows folder picker never lists files: use the Qt dialog so the
        # photos inside are visible (greyed) while picking the folder
        dlg = QFileDialog(self, "选择连拍照片所在的文件夹")
        dlg.setFileMode(QFileDialog.Directory)
        dlg.setOption(QFileDialog.DontUseNativeDialog, True)
        dlg.setOption(QFileDialog.ShowDirsOnly, False)
        if dlg.exec() != QDialog.Accepted or not dlg.selectedFiles():
            return
        d = dlg.selectedFiles()[0]
        if not d:
            return
        preview = ImportPreviewDialog(d, self)
        if preview.exec() == QDialog.Accepted and preview.selected:
            self.state.import_paths(preview.selected,merge=preview.merge_groups.isChecked())

    def choose_photo_files(self):
        files, _ = QFileDialog.getOpenFileNames(self, "选择连拍照片（可多选）", "", PHOTO_FILTER)
        if files:
            choice=QMessageBox(self)
            choice.setWindowTitle("导入分组")
            choice.setText("这些连拍照片如何分组？")
            one=choice.addButton("归为一组",QMessageBox.AcceptRole)
            multi=choice.addButton("按间隔分多组",QMessageBox.AcceptRole)
            choice.addButton(QMessageBox.Cancel)
            choice.exec()
            if choice.clickedButton() in (one,multi):self.state.import_paths(files,merge=choice.clickedButton() is one)

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
                          f"邮箱：<a href='mailto:{CONTACT_EMAIL}'>{CONTACT_EMAIL}</a></p>")

    def contact(self):
        box = QMessageBox(self)
        box.setWindowTitle("BirdLock 反馈与交流")
        box.setText(CONTACT_TEXT)
        copy = box.addButton("复制邮箱", QMessageBox.ActionRole)
        box.addButton("关闭", QMessageBox.RejectRole)
        box.exec()
        if box.clickedButton() is copy:
            from PySide6.QtWidgets import QApplication
            QApplication.clipboard().setText(CONTACT_EMAIL)

    def support(self):
        from ..core.paths import resource_dir
        dialog = QDialog(self); dialog.setWindowTitle("请作者喝杯咖啡")
        layout = QVBoxLayout(dialog)
        text = QLabel("如果 BirdLock 帮到了你，欢迎自愿赞赏。\n5 元、10 元、20 元或任意金额，心意随意。\n所有功能均可免费使用，赞赏不影响使用。")
        text.setWordWrap(True); text.setAlignment(Qt.AlignCenter); layout.addWidget(text)
        image = QLabel(); image.setAlignment(Qt.AlignCenter)
        candidates = (resource_dir()/"support"/"alipay-coffee.jpg",Path(__file__).resolve().parents[3]/"SharedResources"/"Support"/"alipay-coffee.jpg")
        path = next((p for p in candidates if p.is_file()),None)
        pixmap = QPixmap(str(path)) if path else QPixmap()
        if pixmap.isNull():image.setText("暂时找不到赞赏二维码，可通过邮箱联系作者。")
        else:image.setPixmap(pixmap.scaled(QSize(340,510),Qt.KeepAspectRatio,Qt.SmoothTransformation))
        layout.addWidget(image); layout.addWidget(QLabel("支付宝扫码 · 自愿支持"))
        close = QPushButton("关闭"); close.clicked.connect(dialog.accept); layout.addWidget(close)
        dialog.exec()

    def clear_cache(self):
        size = self.state.cache.total_size() / (1 << 20)
        if QMessageBox.question(self, "清空缓存", f"缓存占用约 {size:.0f} MB（缩略图、分析结果和照片编辑）。\n清空会移除已保存的手动修正、排除帧和特写设置，下次打开需要重新分析。\n请先保存需要的成片。确定清空？", QMessageBox.Yes | QMessageBox.No, QMessageBox.No) \
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
        self.state.close()
        super().closeEvent(ev)
