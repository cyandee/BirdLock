"""Experimental video import settings; decoding runs through AppState's cancellable worker."""
import threading

from PySide6.QtCore import Signal, Qt
from PySide6.QtWidgets import (QComboBox, QDialog, QDoubleSpinBox, QFileDialog, QFormLayout, QHBoxLayout, QLineEdit,
                               QLabel, QPushButton, QVBoxLayout)

from ..core.lens_profile import LensProfile
from ..core.video_import import probe, selection
from .lens_picker import SearchableLensCombo
from ..core import lens_catalog


class VideoImportDialog(QDialog):
    loaded = Signal(object, str)

    def __init__(self, path, state, parent=None):
        super().__init__(parent)
        self.path, self.state, self.profile, self.info = path, state, None, None
        self.profile_edited = False
        self.setWindowTitle('导入视频（实验）')
        self.setMinimumWidth(520)
        layout = QVBoxLayout(self)
        title = QLabel(path); title.setWordWrap(True); layout.addWidget(title)
        self.summary = QLabel('正在读取视频信息…'); layout.addWidget(self.summary)
        form = QFormLayout()
        self.start, self.seconds, self.fps = [QDoubleSpinBox() for _ in range(3)]
        for spin in (self.start, self.seconds, self.fps): spin.setDecimals(3); spin.setEnabled(False)
        self.start.setRange(0, 864000)
        self.seconds.setRange(.001, 120); self.seconds.setValue(10)
        self.fps.setRange(1, 60); self.fps.setValue(30)
        for text, spin in [('片段起点（秒）', self.start), ('片段时长（秒）', self.seconds), ('采样帧率', self.fps)]:
            form.addRow(text, spin)
        layout.addLayout(form)
        self.camera = QLabel(); self.camera.setWordWrap(True); layout.addWidget(self.camera)
        self.catalog_entries=[]
        layout.addWidget(QLabel('镜头配置（可选）'))
        self.catalog = SearchableLensCombo(); self.catalog.setEnabled(False)
        self.catalog.valueSelected.connect(self.choose_builtin)
        self.catalog.searchEdited.connect(self.search_changed)
        layout.addWidget(self.catalog)
        row = QHBoxLayout()
        choose = QPushButton('导入镜头配置…'); choose.clicked.connect(self.choose_profile)
        self.choose = choose; choose.setEnabled(False)
        self.remove = QPushButton('清除配置'); self.remove.clicked.connect(self.remove_profile); self.remove.setEnabled(False)
        help_button = QPushButton('查找配置'); help_button.clicked.connect(lambda: self.help.setVisible(not self.help.isVisible()))
        row.addWidget(choose); row.addWidget(self.remove); row.addStretch(); row.addWidget(help_button); layout.addLayout(row)
        self.lens = QLabel(''); self.lens.hide()
        self.camera.setTextFormat(Qt.PlainText); self.lens.setTextFormat(Qt.PlainText)
        self.match = QLabel(); self.match.setWordWrap(True); layout.addWidget(self.match)
        self.help = QLabel(lens_catalog.HELP_TEXT + f'<br><a href="{lens_catalog.DATABASE_URL}">镜头配置库</a> · <a href="{lens_catalog.CALIBRATION_URL}">镜头标定教程</a>')
        self.help.setWordWrap(True); self.help.setOpenExternalLinks(True); self.help.hide(); layout.addWidget(self.help)
        self.clip_summary = QLabel(); layout.addWidget(self.clip_summary)
        self.clip_summary.setWordWrap(True)
        for spin in (self.start,self.seconds,self.fps): spin.valueChanged.connect(self.validate_selection)
        self.message = QLabel(); self.message.setWordWrap(True); layout.addWidget(self.message)
        row = QHBoxLayout()
        cancel = QPushButton('取消'); cancel.clicked.connect(self.reject)
        self.go = QPushButton('导入并分析'); self.go.setObjectName('primary'); self.go.setEnabled(False)
        self.go.clicked.connect(self.import_video)
        row.addWidget(cancel); row.addStretch(); row.addWidget(self.go); layout.addLayout(row)
        self.loaded.connect(self.on_loaded)
        def work():
            try:
                info = probe(path)
                try:
                    match = lens_catalog.detect(path, info.width, info.height, info.fps)
                    self.loaded.emit((info, match, lens_catalog.entries()), '')
                except (OSError,ValueError) as error:self.loaded.emit(info, str(error))
            except Exception as error: self.loaded.emit(None, str(error))
        threading.Thread(target=work, daemon=True).start()

    def on_loaded(self, info, error):
        if isinstance(info, tuple):
            info, match, catalog = info
            self.catalog_entries=catalog;self.catalog.set_entries(catalog)
            self.apply_match(match, automatic=True)
        self.info = info
        if info is None:
            self.message.setText(error); self.summary.setText('无法导入此视频'); return
        for control in (self.start,self.seconds,self.fps,self.catalog,self.choose):control.setEnabled(True)
        self.summary.setText(f'{info.width} × {info.height} · {info.fps:.3f} fps · {info.duration:.2f} 秒')
        self.seconds.setValue(min(10, info.duration)); self.fps.setValue(min(30, info.fps))
        if error:self.message.setText(error)
        self.validate_selection()

    def choose_profile(self):
        path, _ = QFileDialog.getOpenFileName(self, '选择镜头配置或索尼 XML', '', '镜头配置 (*.json *.xml *.XML)')
        if not path: return
        self.profile_edited = True
        try:
            if path.lower().endswith('.xml'):
                match = lens_catalog.import_xml(path, width=self.info.width if self.info else None,
                    height=self.info.height if self.info else None, fps=self.info.fps if self.info else None)
                self.apply_match(match); self.message.clear(); return
            lens = LensProfile.load(path)
            if self.info: lens.maps(self.info.width, self.info.height)
            self.commit_profile(path,lens.name); self.message.clear()
        except Exception as error: self.message.setText(str(error))

    def commit_profile(self, path, title=''):
        self.profile = path or None; self.lens.setText(title)
        self.catalog.set_selection(path,title); self.remove.setEnabled(bool(path))

    def remove_profile(self):
        self.profile_edited = True
        self.commit_profile(None); self.message.clear()

    def apply_match(self, match, automatic=False):
        self.camera.setText(match.metadata.display_name)
        self.match.setText('' if match.selected_url else match.message)
        if not automatic or not self.profile_edited:
            self.commit_profile(str(match.selected_url) if match.selected_url else None,match.selected.title if match.selected else '')
        if self.profile: self.match.clear()

    def choose_builtin(self, path):
        self.profile_edited = True
        if not path: self.commit_profile(None); self.message.clear(); return
        try:
            lens = LensProfile.load(path)
            if self.info: lens.maps(self.info.width, self.info.height)
            title = next((e.title for e in self.catalog_entries if str(e.url)==path),lens.name)
            self.commit_profile(path,title); self.message.clear(); self.match.clear()
        except Exception as error: self.message.setText(str(error))

    def search_changed(self, active, count):
        if active: self.profile_edited = True
        self.validate_selection()

    def validate_selection(self):
        if not hasattr(self,'go'): return False
        if self.info is None: self.go.setEnabled(False); return False
        try:
            seconds,fps,count = selection(self.info,self.start.value(),self.seconds.value(),self.fps.value())
            text = f'片段 {self.start.value():.2f}–{self.start.value()+seconds:.2f} 秒 · {count} 帧 · {fps:.3f} fps'
            if self.catalog.searching: text = '请从匹配列表选择配置，或按 Esc 取消搜索。'
            self.clip_summary.setText(text)
            self.go.setEnabled(not self.catalog.searching)
            return not self.catalog.searching
        except ValueError as error:
            self.clip_summary.setText(str(error));self.go.setEnabled(False);return False

    def import_video(self):
        if not self.validate_selection(): return
        self.state.import_video(self.path, self.start.value(), self.seconds.value(), self.fps.value(), self.profile)
        self.accept()
