"""Independent audio layers; preview and export use the same mixer."""
import os

from PySide6.QtWidgets import (QCheckBox, QComboBox, QDoubleSpinBox, QFileDialog, QHBoxLayout,
                               QLabel, QPushButton, QVBoxLayout, QWidget)

from .inspector import Card, caption
from ..core.settings import AudioTrack
from ..core.sounds import assets, burst_assets, cameras, canonical_id


class AudioTracksCard(Card):
    def __init__(self, state):
        super().__init__("音效与多轨", "♫")
        self.state = state
        self.keys = None
        self.refreshers = []
        self.sounds = CameraSoundPicker()
        self.add(self.sounds)
        buttons = QHBoxLayout()
        shutter = QPushButton("添加快门声")
        shutter.clicked.connect(self.add_shutter)
        upload = QPushButton("添加音频…")
        upload.clicked.connect(self.add_files)
        buttons.addWidget(shutter)
        buttons.addWidget(upload)
        self.add(buttons)
        self.add(caption("快门与背景音乐同时播放。各轨独立调节；长度为 0 时延续至视频结束。混音自动预留音量余量。"))
        self.layers = QWidget()
        self.layers.setMinimumWidth(1)
        self.layer_layout = QVBoxLayout(self.layers)
        self.layer_layout.setContentsMargins(0, 0, 0, 0)
        self.add(self.layers)
        self.message = caption("")
        self.add(self.message)
        state.changed.connect(self.refresh)
        self.refresh("audio")

    def add_shutter(self):
        if self.sounds.asset_id:
            self.state.audio.tracks.append(AudioTrack(assetID=self.sounds.asset_id, volume=0.5, fadeIn=0, fadeOut=0))
            self.state.audio_settings_changed()

    def add_files(self):
        paths, _ = QFileDialog.getOpenFileNames(self, "添加独立音轨", "", "音频 (*.mp3 *.wav *.m4a *.aac *.aiff *.aif *.flac *.mp4 *.mov);;所有文件 (*)")
        for path in paths:
            self.state.audio.tracks.append(AudioTrack(path=path, volume=0.5, fadeIn=0, fadeOut=0))
        if paths:
            self.state.audio_settings_changed()

    def refresh(self, topic):
        if topic not in ("audio", "job", "all"):
            return
        keys = tuple(id(t) for t in self.state.audio.tracks)
        if keys != self.keys:
            self.keys = keys
            self.refreshers = []
            while self.layer_layout.count():
                item = self.layer_layout.takeAt(0)
                widget = item.widget()
                if widget:
                    widget.hide()
                    widget.setParent(None)
                    widget.deleteLater()
            for index, track in enumerate(self.state.audio.tracks):
                self.layer_layout.addWidget(self.editor(index, track))
        for refresh in self.refreshers:
            refresh()
        self.message.setText(self.state.audio_message)
        self.message.setVisible(bool(self.state.audio_message))

    def editor(self, index, track):
        box = Card(f"音轨 {index + 1}")
        name = caption("")
        box.add(name)
        self.refreshers.append(lambda: name.setText(next((e["title"] for e in assets() if e["id"] == canonical_id(track.assetID)), os.path.basename(track.path) or "已移除档位，请重新选择")))
        if track.assetID:
            choice = CameraSoundPicker(track.assetID, lambda value: self.set(track, "assetID", value))
            box.add(choice)
        for label, key in (("静音", "muted"), ("循环播放", "loop")):
            check = QCheckBox(label)
            check.setChecked(getattr(track, key))
            check.toggled.connect(lambda value, k=key: self.set(track, k, value))
            box.add(check)
        for label, key, limit, suffix in (("音量", "volume", 1.5, " ×"), ("视频起点", "timelineStart", 86400, " 秒"),
                                         ("播放长度", "duration", 86400, " 秒"), ("素材起点", "startOffset", 86400, " 秒"),
                                         ("淡入", "fadeIn", 5, " 秒"), ("淡出", "fadeOut", 5, " 秒")):
            row = QHBoxLayout()
            row.addWidget(QLabel(label))
            spin = QDoubleSpinBox()
            spin.setRange(0, limit)
            spin.setDecimals(2)
            spin.setSingleStep(0.1)
            spin.setSuffix(suffix)
            spin.setValue(getattr(track, key))
            spin.setKeyboardTracking(False)
            spin.valueChanged.connect(lambda value, k=key: self.set(track, k, value))
            row.addWidget(spin)
            box.add(row)

            def refresh_value(control=spin, k=key):
                control.blockSignals(True)
                control.setValue(getattr(track, k))
                control.blockSignals(False)
            self.refreshers.append(refresh_value)
        missing = caption("找不到该音频文件，请重新添加。")
        self.refreshers.append(lambda: missing.setVisible(not os.path.isfile(track.source_path)))
        box.add(missing)
        remove = QPushButton("移除这条音轨")

        def delete():
            self.state.audio.tracks = [t for t in self.state.audio.tracks if t is not track]
            self.state.audio_settings_changed()
        remove.clicked.connect(delete)
        box.add(remove)
        return box

    def set(self, track, key, value):
        setattr(track, key, value)
        self.state.audio_settings_changed()


class CameraSoundPicker(QWidget):
    def __init__(self, asset_id="sony-a1m2-30", changed=None):
        super().__init__()
        self.changed = None
        self.camera = QComboBox(); self.recording = QComboBox()
        layout = QVBoxLayout(self); layout.setContentsMargins(0,0,0,0)
        layout.addWidget(QLabel("相机")); layout.addWidget(self.camera)
        layout.addWidget(QLabel("fps / 录音")); layout.addWidget(self.recording)
        for key,title in cameras(): self.camera.addItem(title,key)
        entry = next((e for e in burst_assets() if e["id"]==canonical_id(asset_id)),None)
        if entry is None and asset_id:self.camera.addItem("请选择相机","unavailable")
        self.camera.setCurrentIndex(max(0,self.camera.findData(entry["cameraID"] if entry else "unavailable")))
        self.populate(canonical_id(asset_id))
        self.changed = changed
        self.camera.currentIndexChanged.connect(lambda _: self.populate())
        self.recording.currentIndexChanged.connect(lambda _: self.notify())

    @property
    def asset_id(self): return self.recording.currentData() or ""

    def populate(self, selected=None):
        self.recording.blockSignals(True); self.recording.clear()
        for e in burst_assets():
            if e["cameraID"] == self.camera.currentData(): self.recording.addItem(e["variant"],e["id"])
        if selected:
            if self.recording.findData(selected)<0:self.recording.addItem("已移除档位，请重新选择",selected)
            self.recording.setCurrentIndex(self.recording.findData(selected))
        self.recording.blockSignals(False)
        self.notify()

    def notify(self):
        if self.changed and self.asset_id: self.changed(self.asset_id)
