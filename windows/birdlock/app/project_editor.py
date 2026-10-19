"""Editing controls for photo burst groups, replacement closeups and local music cues."""
from PySide6.QtWidgets import (QCheckBox,QComboBox,QDoubleSpinBox,QHBoxLayout,QLabel,QPushButton,QVBoxLayout,QWidget)
from .inspector import Card,caption
from ..core.settings import FocusMarkColor
from ..core.music_cues import visual_candidates


class ProjectEditor(Card):
    def __init__(self,state):
        super().__init__("连拍与特写", "▣")
        self.state=state; self.signature=None; self.refreshers=[]
        self.body=QWidget();self.rows=QVBoxLayout(self.body);self.rows.setContentsMargins(0,0,0,0)
        self.message=caption("");self.message.hide();self.add(self.message)
        self.add(self.body)
        state.changed.connect(self.refresh)
        self.refresh("analysis")

    def refresh(self,topic):
        if topic not in ("analysis","frames","phase","all"):return
        self.message.setText(self.state.timeline_message)
        self.message.setVisible(bool(self.state.timeline_message))
        a=self.state.analysis
        signature=(self.state.phase,self.state.segment_index,tuple(self.state.merge_group_indices),tuple((s.start,s.stop) for s in self.state.segments),tuple(id(s) for s in a.closeups) if a else (),a.fingerprint if a else None)
        if signature==self.signature:
            for fn in self.refreshers:fn()
            return
        self.signature=signature;self.refreshers=[]
        while self.rows.count():
            item=self.rows.takeAt(0)
            widget=item.widget()
            if widget:
                widget.hide();widget.setParent(None);widget.deleteLater()
        if len(self.state.segments)>1:
            mode=QComboBox();mode.addItem("多组分别切换",0);mode.addItem("选中组合为同一视频",-1)
            mode.setCurrentIndex(1 if self.state.segment_index==-1 else 0)
            mode.currentIndexChanged.connect(lambda _:self.state.select_segment(-1 if mode.currentData()==-1 else 0))
            self.rows.addWidget(mode)
            for i,seg in enumerate(self.state.segments):
                check=QCheckBox(f"合并第 {i+1} 组（{seg.count} 张）")
                check.setChecked(i in self.state.merge_group_indices)
                check.toggled.connect(lambda v,k=i:self.state.include_group(k,v))
                self.rows.addWidget(check)
            self.rows.addWidget(caption("片段播放顺序（上移提前播放，下移延后播放）"))
            for position,group in enumerate(self.state.merge_group_indices):
                row=QHBoxLayout();row.addWidget(QLabel(f"{position+1}. 第 {group+1} 组"))
                for label,delta,enabled in (("上移",-1,position>0),("下移",1,position+1<len(self.state.merge_group_indices))):
                    button=QPushButton(label);button.setEnabled(enabled and self.state.phase=="ready")
                    button.clicked.connect(lambda _,g=group,d=delta:self.state.move_group(g,d));row.addWidget(button)
                holder=QWidget();holder.setLayout(row);self.rows.addWidget(holder)
        add=QPushButton("将当前照片设为特写");add.setEnabled(a is not None);add.clicked.connect(self.state.add_closeup)
        self.rows.addWidget(add)
        self.rows.addWidget(caption("特写替换所选照片时段；放大与移动只影响该镜头。时段不可重叠。"))
        if a is None:return
        for shot in a.closeups:self.rows.addWidget(self.editor(shot))

    def editor(self,shot):
        box=Card(f"特写：第 {shot.frame+1} 帧")
        select=QPushButton("预览这张特写")
        select.clicked.connect(lambda:self.state.seek(shot.frame));box.add(select)
        def field(label,key,lo,hi,step=0.1,offset=0):
            row=QHBoxLayout();row.addWidget(QLabel(label))
            spin=QDoubleSpinBox();spin.setRange(lo,hi);spin.setSingleStep(step);spin.setDecimals(0 if offset else 2);spin.setKeyboardTracking(False)
            spin.setObjectName(f"closeup-{id(shot)}-{key}")
            spin.setAccessibleName(label)
            spin.setValue(getattr(shot,key)+offset)
            def changed(value):
                value=int(value-offset) if offset else value
                old,old_end=getattr(shot,key),shot.endFrame
                setattr(shot,key,value)
                shot.endFrame=max(shot.frame,shot.endFrame)
                if any(s is not shot and s.frame<=shot.endFrame and shot.frame<=s.endFrame for s in self.state.analysis.closeups):
                    setattr(shot,key,old);shot.endFrame=old_end
                    self.state.timeline_message="特写替换时段不能重叠。"
                    self.state.changed.emit("analysis")
                    return
                self.state.timeline_message=""
                self.state.project_changed()
            spin.valueChanged.connect(changed);row.addWidget(spin);box.add(row)
            def refresh():
                spin.blockSignals(True);spin.setValue(getattr(shot,key)+offset);spin.blockSignals(False)
            self.refreshers.append(refresh)
        field("起始照片","frame",1,self.state.analysis.count,1,1)
        field("替换至照片","endFrame",1,self.state.analysis.count,1,1)
        field("展示秒数","seconds",0.04,3600)
        field("照片放大","zoom",1,8)
        field("构图横向 0—1","centerX",0,1,0.01)
        field("构图纵向 0—1","centerY",0,1,0.01)
        shutter=QCheckBox("单张快门声");shutter.setChecked(shot.shutterEnabled)
        shutter.toggled.connect(lambda v:(setattr(shot,"shutterEnabled",v),self.state.project_changed()));box.add(shutter)
        field("快门音量","shutterVolume",0,1.5)
        animated=QCheckBox("动态特写框");animated.setChecked(shot.animatedFrame)
        animated.toggled.connect(lambda v:(setattr(shot,"animatedFrame",v),self.state.project_changed()));box.add(animated)
        colors=QComboBox()
        for c in FocusMarkColor:colors.addItem(c.title,c)
        colors.setCurrentIndex(colors.findData(shot.color))
        colors.currentIndexChanged.connect(lambda _:(setattr(shot,"color",colors.currentData()),self.state.project_changed()));box.add(colors)
        remove=QPushButton("移除特写")
        remove.setObjectName(f"remove-closeup-{id(shot)}")
        def delete():
            self.state.analysis.closeups=[s for s in self.state.analysis.closeups if s is not shot]
            self.state.timeline_message=""
            self.state.project_changed()
        remove.clicked.connect(delete);box.add(remove)
        return box


class MusicCueCard(Card):
    def __init__(self,state):
        super().__init__("音乐卡点辅助", "♪")
        self.state=state;self.signature=None
        self.add(caption("根据音乐能量变化提供节拍与高潮候选，需试听确认。选择画面后，可让音乐候选点对齐当前画面。"))
        self.visual=QComboBox();self.add(self.visual)
        choose=QPushButton("跳到画面候选")
        choose.clicked.connect(lambda:state.seek(self.visual.currentData()) if self.visual.currentData() is not None else None);self.add(choose)
        self.cues=QComboBox();self.add(self.cues)
        align=QPushButton("音乐候选对齐当前画面");align.clicked.connect(self.align);self.add(align)
        self.message=caption("");self.add(self.message)
        state.changed.connect(self.refresh);self.refresh("analysis")

    def refresh(self,topic):
        if topic not in ("audio","analysis","job","phase"):return
        a=self.state.analysis
        key=(id(self.state.music_cues),id(a),id(self.state.job),tuple(a.excluded) if a else ())
        if key==self.signature:return
        selected_cue, selected_visual = self.cues.currentData(), self.visual.currentData()
        self.signature=key;self.cues.clear();self.visual.clear()
        for cue in sorted(self.state.music_cues,key=lambda c:(not c["climax"],c["time"])):
            self.cues.addItem(f'{"高潮候选" if cue["climax"] else "节拍候选"} · {cue["time"]:.2f} 秒',cue["time"])
        included={of.a for of in self.state.job.output_frames} if self.state.job else None
        for i in visual_candidates(a,included):self.visual.addItem(f"画面候选：第 {i+1} 帧",i)
        if self.cues.findData(selected_cue)>=0:self.cues.setCurrentIndex(self.cues.findData(selected_cue))
        if self.visual.findData(selected_visual)>=0:self.visual.setCurrentIndex(self.visual.findData(selected_visual))
        self.message.setText("请添加背景音乐，或音乐变化不足以产生候选。" if self.cues.count()==0 else "画面候选综合清晰度与主体展开程度，不代表语义识别。")

    def align(self):
        state=self.state;cue=self.cues.currentData()
        if cue is None or state.job is None:return
        from ..core.render import project_source_time
        time=state.playhead/state.job.export.outputFPS if state.playing else project_source_time(state.current_frame,state.job.output_frames,state.job.analysis.closeups)
        if time is None:self.message.setText("当前照片未出现在成片中，请选择有效画面。");return
        if cue<time:self.message.setText("该音乐候选早于当前画面，请选择更早的画面。");return
        state.audio.startOffset=cue-time;state.audio_settings_changed()
